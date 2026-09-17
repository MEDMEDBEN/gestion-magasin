import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'error/api_exception.dart';
import 'error/error_codes.dart';
import 'providers.dart';

/// Contrat d'idempotence côté app (miroir de `backend/src/common/idempotency.ts`).
///
/// Chaque mutation d'ARGENT porte un `clientMutationId`. La clé appartient à
/// une INTENTION (« régler le client X », « payer le fournisseur Y », « ouvrir
/// ma caisse ») et reste la MÊME pour tous les essais de cette intention — délai
/// dépassé, réseau coupé, double clic, dialogue rouvert — jusqu'à ce que le
/// serveur confirme. Un nouvel essai ne peut donc jamais créer un second paiement :
/// le serveur rend l'effet déjà appliqué.
///
/// Liée au compte connecté : un changement d'utilisateur repart de zéro.
class MutationKeys extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    ref.watch(currentUserIdProvider);
    return const {};
  }

  /// Clé de l'intention : créée au premier essai, réutilisée ensuite.
  String keyFor(String intent) {
    final existing = state[intent];
    if (existing != null) return existing;
    final key = ref.read(uuidProvider).v7();
    state = {...state, intent: key};
    return key;
  }

  /// L'intention est close (confirmée par le serveur) : le prochain essai sera
  /// une NOUVELLE opération.
  void release(String intent) {
    if (!state.containsKey(intent)) return;
    state = {...state}..remove(intent);
  }
}

final mutationKeysProvider =
    NotifierProvider<MutationKeys, Map<String, String>>(MutationKeys.new);

/// Codes par lesquels le serveur dit « cette clé a DÉJÀ servi à une autre
/// opération » : l'intention en cours est close, l'utilisateur vérifie.
const _alreadyApplied = {
  ErrorCodes.saleAlreadyRecorded,
  ErrorCodes.paymentAlreadyRecorded,
};

/// Exécute une mutation d'argent sous la clé stable de son intention.
///
/// Succès → clé libérée. Échec réseau ou refus métier (rien n'a été appliqué,
/// ou on ne le sait pas) → clé GARDÉE pour le prochain essai. Clé déjà utilisée
/// par une autre opération → clé libérée, l'erreur remonte à l'écran.
Future<T> runMoneyMutation<T>(
  Ref ref,
  String intent,
  Future<T> Function(String clientMutationId) call,
) async {
  final keys = ref.read(mutationKeysProvider.notifier);
  final key = keys.keyFor(intent);
  try {
    final result = await call(key);
    keys.release(intent);
    return result;
  } on ApiException catch (error) {
    if (_alreadyApplied.contains(error.code)) keys.release(intent);
    rethrow;
  }
}
