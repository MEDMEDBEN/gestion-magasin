import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/data/api/sync_api.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/data/local/mutation_queue.dart';
import 'package:gestion_magasin/data/models/sync_models.dart';
import 'package:gestion_magasin/data/sync/sync_engine.dart';

/// Faux SyncApi : rend les verdicts qu'on lui dicte et compte les appels.
class _FakeSyncApi implements SyncApi {
  _FakeSyncApi(this._respond);

  final SyncBatchResult Function(List<SyncMutationInput>) _respond;
  final List<List<SyncMutationInput>> calls = [];
  ApiException? failure;

  @override
  Future<SyncBatchResult> push(List<SyncMutationInput> mutations) async {
    calls.add(mutations);
    if (failure != null) throw failure!;
    return _respond(mutations);
  }
}

SyncBatchResult _allWith(
  List<SyncMutationInput> mutations,
  SyncStatus status, {
  String? code,
}) {
  return SyncBatchResult(
    serverTime: DateTime.utc(2026, 9, 9).toIso8601String(),
    results: mutations
        .map(
          (m) => SyncResult(
            clientMutationId: m.clientMutationId,
            status: status,
            code: code,
          ),
        )
        .toList(),
  );
}

void main() {
  late AppDatabase db;
  late MutationQueue queue;

  setUp(() {
    db = AppDatabase.forTesting();
    queue = MutationQueue(db);
  });

  tearDown(() => db.close());

  const author = 'compte-a';

  Future<String> enqueue([DateTime? at, String authorUserId = author]) =>
      queue.enqueue(
        authorUserId: authorUserId,
        deviceId: 'appareil-test',
        operationType: 'MANUAL',
        payload: {'quantity': '1.000'},
        deviceTimestamp: at ?? DateTime.now().toUtc(),
      );

  test('file vide : aucun appel réseau', () async {
    final api = _FakeSyncApi((m) => _allWith(m, SyncStatus.confirmee));
    final outcome = await SyncEngine(
      api: api,
      queue: queue,
    ).synchronize(authorUserId: author);

    expect(api.calls, isEmpty);
    expect(outcome.isFullySynced, isTrue);
  });

  test('les mutations confirmées quittent la file', () async {
    await enqueue();
    await enqueue();
    final api = _FakeSyncApi((m) => _allWith(m, SyncStatus.confirmee));

    final outcome = await SyncEngine(
      api: api,
      queue: queue,
    ).synchronize(authorUserId: author);

    expect(outcome.sent, 2);
    expect(outcome.confirmed, 2);
    expect(outcome.stillPending, 0);
    expect(outcome.isFullySynced, isTrue);
  });

  test('un rejet métier est enregistré, pas réessayé', () async {
    await enqueue();
    final api = _FakeSyncApi(
      (m) => _allWith(m, SyncStatus.rejetee, code: 'STOCK_NEGATIVE'),
    );
    final engine = SyncEngine(api: api, queue: queue);

    final outcome = await engine.synchronize(authorUserId: author);
    expect(outcome.rejected, 1);
    expect(outcome.stillPending, 0);

    // Un second cycle ne doit RIEN renvoyer : le verdict est définitif.
    await engine.synchronize(authorUserId: author);
    expect(api.calls, hasLength(1));

    final rejected = await queue.byStatus(LocalMutationStatus.rejetee);
    expect(rejected.single.rejectionCode, 'STOCK_NEGATIVE');
  });

  test('NON_TRAITEE garde la mutation pour le cycle suivant', () async {
    await enqueue();
    final api = _FakeSyncApi(
      (m) => _allWith(m, SyncStatus.nonTraitee, code: 'NOT_IMPLEMENTED'),
    );
    final engine = SyncEngine(api: api, queue: queue);

    final outcome = await engine.synchronize(authorUserId: author);
    expect(outcome.confirmed, 0);
    expect(outcome.rejected, 0);
    expect(outcome.stillPending, 1);

    await engine.synchronize(authorUserId: author);
    expect(api.calls, hasLength(2), reason: 'elle doit repartir');
  });

  test('une panne réseau NE marque JAMAIS une mutation rejetée', () async {
    final id = await enqueue();
    final api = _FakeSyncApi((m) => _allWith(m, SyncStatus.confirmee))
      ..failure = const ApiException(
        statusCode: 0,
        message: 'Serveur injoignable',
      );

    final outcome = await SyncEngine(
      api: api,
      queue: queue,
    ).synchronize(authorUserId: author);

    expect(outcome.hasFailure, isTrue);
    expect(outcome.stillPending, 1);
    expect(await queue.byStatus(LocalMutationStatus.rejetee), isEmpty);
    // La mutation garde son identifiant : le renvoi restera idempotent.
    expect(
      (await queue.nextBatch(authorUserId: author)).single.clientMutationId,
      id,
    );
  });

  test('le lot part dans l’ordre du timestamp appareil', () async {
    final second = await enqueue(DateTime.utc(2026, 9, 9, 12));
    final first = await enqueue(DateTime.utc(2026, 9, 9, 9));
    final api = _FakeSyncApi((m) => _allWith(m, SyncStatus.confirmee));

    await SyncEngine(api: api, queue: queue).synchronize(authorUserId: author);

    expect(api.calls.single.map((m) => m.clientMutationId).toList(), [
      first,
      second,
    ]);
  });

  test('deux cycles concurrents ne produisent qu’un seul envoi', () async {
    await enqueue();
    final api = _FakeSyncApi((m) => _allWith(m, SyncStatus.confirmee));
    final engine = SyncEngine(api: api, queue: queue);

    await Future.wait([
      engine.synchronize(authorUserId: author),
      engine.synchronize(authorUserId: author),
    ]);

    expect(api.calls, hasLength(1));
  });

  test('synchronizeAll vide une file plus grande qu’un lot', () async {
    for (var i = 0; i < 5; i++) {
      await enqueue(DateTime.utc(2026, 9, 9, 8 + i));
    }
    final api = _FakeSyncApi((m) => _allWith(m, SyncStatus.confirmee));
    final engine = SyncEngine(api: api, queue: queue);

    // On force des lots de 2 en vidant progressivement.
    final outcome = await engine.synchronizeAll(authorUserId: author);

    expect(outcome.stillPending, 0);
    expect(await queue.pendingCount(authorUserId: author), 0);
  });

  test('synchronizeAll s’arrête net sur une panne', () async {
    await enqueue();
    final api = _FakeSyncApi((m) => _allWith(m, SyncStatus.confirmee))
      ..failure = const ApiException(statusCode: 0, message: 'hors ligne');

    final outcome = await SyncEngine(
      api: api,
      queue: queue,
    ).synchronizeAll(authorUserId: author);

    expect(outcome.hasFailure, isTrue);
    expect(api.calls, hasLength(1));
  });

  test(
    'ne pousse JAMAIS les mutations d’un autre compte (poste partagé)',
    () async {
      final mine = await enqueue(DateTime.utc(2026, 9, 9, 9));
      await enqueue(DateTime.utc(2026, 9, 9, 8), 'compte-b');
      final api = _FakeSyncApi((m) => _allWith(m, SyncStatus.confirmee));

      await SyncEngine(
        api: api,
        queue: queue,
      ).synchronize(authorUserId: author);

      // Envoyées avec la session de A, celles de B seraient attribuées à A par
      // le serveur (et jugées selon SES droits) : elles restent en quarantaine.
      expect(api.calls.single.map((m) => m.clientMutationId), [mine]);
      expect(await queue.pendingCount(authorUserId: 'compte-b'), 1);
    },
  );
}
