import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'error/api_exception.dart';
import 'error/error_codes.dart';
import 'mutation_keys.dart';
import 'providers.dart';

/// Issue d'une écriture : appliquée par le serveur, ou mise en file hors-ligne.
sealed class WriteOutcome<T> {
  const WriteOutcome();
}

/// Le serveur a répondu : l'opération est DÉFINITIVE.
final class Applied<T> extends WriteOutcome<T> {
  const Applied(this.value);
  final T value;
}

/// Pas de réseau : l'opération attend dans la file. Elle n'est PAS définitive —
/// l'écran doit l'afficher « en attente de synchronisation », jamais comme
/// faite (docs/context.md §6).
final class Queued<T> extends WriteOutcome<T> {
  const Queued(this.clientMutationId);
  final String clientMutationId;
}

/// Écrit EN LIGNE si possible, sinon met en FILE — avec la même clé.
///
/// La clé est celle de l'INTENTION (`MutationKeys`), identique pour l'essai en
/// ligne et pour la mutation mise en file. Si l'essai en ligne est arrivé au
/// serveur mais que la réponse s'est perdue (délai dépassé), la mutation mise en
/// file porte la clé de l'entité DÉJÀ créée. PRÉCONDITION, à tenir par chaque
/// handler de sync (docs/context.md, 2026-09-21) : reconnaître cette entité et
/// rendre CONFIRMEE sans la réappliquer — le moteur, lui, ne déduplique que ses
/// propres mutations mémorisées. Jamais pour une facture (règle 11).
///
/// `payload` reçoit la clé : le corps envoyé en ligne et celui mis en file sont
/// construits par la MÊME fonction — ils ne peuvent pas diverger.
///
/// `intent` doit désigner UNE opération (`sale:<idDuPanier>`), jamais un
/// geste générique (« sale ») : deux opérations sous la même intention
/// partageraient une clé tant que la première n'est pas close.
Future<WriteOutcome<T>> writeOnlineOrQueue<T>(
  Ref ref, {
  required String intent,
  required String operationType,
  required Map<String, dynamic> Function(String clientMutationId) payload,
  required Future<T> Function(Map<String, dynamic> body) online,
}) async {
  // L'auteur est celui qui a FAIT le geste, lu AVANT l'attente réseau : un autre
  // compte peut se connecter pendant qu'elle dure (audit sécu E1).
  final author = ref.read(currentUserIdProvider);
  if (author == null) {
    throw StateError('Écriture sans compte connecté');
  }
  final keys = ref.read(mutationKeysProvider.notifier);
  final key = keys.keyFor(intent);
  final body = payload(key);
  try {
    final value = await online(body);
    keys.release(intent);
    return Applied(value);
  } on ApiException catch (error) {
    if (!error.isOffline) {
      // Refus métier ou conflit : même règle que les mutations d'argent.
      if (alreadyAppliedCodes.contains(error.code)) keys.release(intent);
      rethrow;
    }
    // Session changée pendant l'essai : l'intention appartient à une session
    // CLOSE. La mettre en file l'étiquetterait au nouveau compte, qui la ferait
    // passer sous ses propres droits — on ne met rien en file.
    if (ref.read(currentUserIdProvider) != author) rethrow;
    final queue = ref.read(mutationQueueProvider);
    // Borne du contrat (docs/context.md, « Bornes de données offline ») : un
    // appareil trop longtemps hors-ligne travaille sur un stock trop faux.
    if (await queue.isTooStale(authorUserId: author)) {
      throw const ApiException(
        statusCode: 409,
        code: ErrorCodes.offlineTooLong,
        message:
            'Trop longtemps hors ligne : reconnectez l’appareil pour '
            'synchroniser avant de nouvelles opérations',
      );
    }
    await queue.enqueue(
      authorUserId: author,
      deviceId: await ref.read(deviceIdProvider.future),
      operationType: operationType,
      payload: body,
      clientMutationId: key,
    );
    // La FILE détient désormais l'intention : un nouvel essai serait une
    // nouvelle opération (la mutation en file partira de toute façon).
    keys.release(intent);
    return Queued(key);
  }
}
