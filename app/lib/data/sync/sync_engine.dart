import '../../core/error/api_exception.dart';
import '../api/sync_api.dart';
import '../local/mutation_queue.dart';
import '../models/sync_models.dart';

/// Résultat d'un cycle de synchronisation, pour l'indicateur permanent de l'UI.
class SyncOutcome {
  const SyncOutcome({
    required this.sent,
    required this.confirmed,
    required this.rejected,
    required this.stillPending,
    this.failure,
  });

  const SyncOutcome.offline(this.stillPending)
      : sent = 0,
        confirmed = 0,
        rejected = 0,
        failure = 'Pas de connexion au serveur';

  final int sent;
  final int confirmed;
  final int rejected;
  final int stillPending;

  /// Renseigné si le cycle n'a pas pu aboutir (hors-ligne, serveur en erreur).
  final String? failure;

  bool get hasFailure => failure != null;
  bool get isFullySynced => stillPending == 0 && !hasFailure;
}

/// Pousse la file de mutations vers `POST /api/sync` et applique les verdicts.
///
/// Le moteur ne décide RIEN sur le fond : il transporte, puis obéit au verdict
/// serveur. C'est le serveur qui fait autorité (docs/context.md §4).
class SyncEngine {
  SyncEngine({required this._api, required this._queue});

  final SyncApi _api;
  final MutationQueue _queue;

  /// Empêche deux cycles concurrents : ils enverraient les mêmes mutations
  /// deux fois. Le serveur est idempotent, mais autant ne pas l'éprouver.
  Future<SyncOutcome>? _inFlight;

  /// Pousse les mutations de `authorUserId` — le compte dont la session porte
  /// l'envoi. Celles d'un autre compte ne partent jamais avec cette session : le
  /// serveur les attribuerait (et les jugerait) au mauvais utilisateur.
  Future<SyncOutcome> synchronize({required String authorUserId}) {
    return _inFlight ??=
        _run(authorUserId).whenComplete(() => _inFlight = null);
  }

  Future<SyncOutcome> _run(String authorUserId) async {
    final rows = await _queue.nextBatch(authorUserId: authorUserId);
    if (rows.isEmpty) {
      return const SyncOutcome(
        sent: 0,
        confirmed: 0,
        rejected: 0,
        stillPending: 0,
      );
    }

    final inputs = await _queue.toInputs(rows);
    if (inputs.isEmpty) {
      // Toutes les lignes du lot étaient corrompues : elles viennent d'être
      // écartées, rien à envoyer.
      return SyncOutcome(
        sent: 0,
        confirmed: 0,
        rejected: rows.length,
        stillPending: await _queue.pendingCount(authorUserId: authorUserId),
      );
    }
    await _queue.markAttempted(inputs.map((m) => m.clientMutationId).toList());

    final SyncBatchResult batch;
    try {
      batch = await _api.push(inputs);
    } on ApiException catch (error) {
      // Rien n'est perdu : les mutations restent en attente et repartiront.
      // Ne JAMAIS les marquer rejetées ici — l'échec est transport, pas métier.
      return SyncOutcome(
        sent: inputs.length,
        confirmed: 0,
        rejected: 0,
        stillPending: await _queue.pendingCount(authorUserId: authorUserId),
        failure: error.userMessage,
      );
    }

    var confirmed = 0;
    var rejected = 0;
    for (final result in batch.results) {
      await _queue.applyResult(result);
      switch (result.status) {
        case SyncStatus.confirmee:
          confirmed++;
        case SyncStatus.rejetee:
          rejected++;
        case SyncStatus.nonTraitee:
          break; // reste en file, repartira au prochain cycle
      }
    }

    return SyncOutcome(
      sent: inputs.length,
      confirmed: confirmed,
      rejected: rejected,
      stillPending: await _queue.pendingCount(authorUserId: authorUserId),
    );
  }

  /// Vide la file en boucle tant que le serveur confirme des mutations.
  /// Utile après une longue coupure : la file peut dépasser un lot.
  Future<SyncOutcome> synchronizeAll({
    required String authorUserId,
    int maxBatches = 10,
  }) async {
    var last = await synchronize(authorUserId: authorUserId);
    var batches = 1;

    while (!last.hasFailure &&
        last.stillPending > 0 &&
        last.confirmed > 0 &&
        batches < maxBatches) {
      last = await synchronize(authorUserId: authorUserId);
      batches++;
    }
    return last;
  }
}
