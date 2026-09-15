import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/data/local/mutation_queue.dart';
import 'package:gestion_magasin/data/models/sync_models.dart';

/// La file de mutations est le pendant client du contrat de sync
/// (docs/context.md §2 et §6). Base SQLite EN MÉMOIRE : aucun plugin natif.
void main() {
  late AppDatabase db;
  late MutationQueue queue;

  setUp(() {
    db = AppDatabase.forTesting();
    queue = MutationQueue(db);
  });

  tearDown(() => db.close());

  const author = 'compte-a';

  Future<String> enqueueAt(
    DateTime timestamp, {
    String type = 'MANUAL',
    String authorUserId = author,
  }) {
    return queue.enqueue(
      authorUserId: authorUserId,
      deviceId: 'appareil-test',
      operationType: type,
      payload: {'quantity': '2.000'},
      deviceTimestamp: timestamp,
    );
  }

  test('une mutation enfilée est en attente et compte dans le total', () async {
    await enqueueAt(DateTime.utc(2026, 9, 9, 10));

    expect(await queue.pendingCount(authorUserId: author), 1);
    final batch = await queue.nextBatch(authorUserId: author);
    expect(batch, hasLength(1));
    expect(batch.first.status, LocalMutationStatus.enAttente);
  });

  test('chaque mutation reçoit un clientMutationId UNIQUE', () async {
    final first = await enqueueAt(DateTime.utc(2026, 9, 9, 10));
    final second = await enqueueAt(DateTime.utc(2026, 9, 9, 11));

    expect(first, isNot(second));
  });

  test(
    'le lot est ordonné par timestamp APPAREIL, pas par insertion',
    () async {
      final late_ = await enqueueAt(DateTime.utc(2026, 9, 9, 12));
      final early = await enqueueAt(DateTime.utc(2026, 9, 9, 8));
      final middle = await enqueueAt(DateTime.utc(2026, 9, 9, 10));

      final batch = await queue.nextBatch(authorUserId: author);

      expect(
        batch.map((m) => m.clientMutationId).toList(),
        [early, middle, late_],
        reason: "l'ordre métier dépend du timestamp appareil",
      );
    },
  );

  test('le lot est plafonné à la limite demandée', () async {
    for (var i = 0; i < 5; i++) {
      await enqueueAt(DateTime.utc(2026, 9, 9, 8 + i));
    }

    expect(await queue.nextBatch(authorUserId: author, limit: 3), hasLength(3));
  });

  test('CONFIRMEE retire définitivement la mutation de la file', () async {
    final id = await enqueueAt(DateTime.utc(2026, 9, 9, 10));

    await queue.applyResult(
      SyncResult(
        clientMutationId: id,
        status: SyncStatus.confirmee,
        entityId: 'mouvement-1',
      ),
    );

    expect(await queue.pendingCount(authorUserId: author), 0);
    expect(await queue.nextBatch(authorUserId: author), isEmpty);
  });

  test('REJETEE conserve la mutation avec son code métier stable', () async {
    final id = await enqueueAt(DateTime.utc(2026, 9, 9, 10));

    await queue.applyResult(
      SyncResult(
        clientMutationId: id,
        status: SyncStatus.rejetee,
        code: 'STOCK_NEGATIVE',
        reason: 'Stock insuffisant',
      ),
    );

    // Elle ne doit PAS repartir toute seule : l'utilisateur doit trancher.
    expect(await queue.nextBatch(authorUserId: author), isEmpty);

    final rejected = await queue.byStatus(LocalMutationStatus.rejetee);
    expect(rejected, hasLength(1));
    expect(rejected.first.rejectionCode, 'STOCK_NEGATIVE');
    expect(rejected.first.rejectionReason, 'Stock insuffisant');
  });

  test('NON_TRAITEE laisse la mutation en file pour un renvoi', () async {
    final id = await enqueueAt(DateTime.utc(2026, 9, 9, 10));

    await queue.applyResult(
      SyncResult(
        clientMutationId: id,
        status: SyncStatus.nonTraitee,
        code: 'SYNC_RETRY_LATER',
      ),
    );

    expect(await queue.pendingCount(authorUserId: author), 1);
    expect(await queue.nextBatch(authorUserId: author), hasLength(1));
  });

  test('un renvoi réutilise le MÊME clientMutationId (idempotence)', () async {
    final id = await enqueueAt(DateTime.utc(2026, 9, 9, 10));

    final first = await queue.nextBatch(authorUserId: author);
    await queue.applyResult(
      SyncResult(clientMutationId: id, status: SyncStatus.nonTraitee),
    );
    final second = await queue.nextBatch(authorUserId: author);

    expect(second.first.clientMutationId, first.first.clientMutationId);
    expect(second.first.clientMutationId, id);
  });

  test('markAttempted incrémente le compteur sans changer le statut', () async {
    final id = await enqueueAt(DateTime.utc(2026, 9, 9, 10));

    await queue.markAttempted([id]);
    await queue.markAttempted([id]);

    final row = (await queue.nextBatch(authorUserId: author)).first;
    expect(row.attemptCount, 2);
    expect(row.status, LocalMutationStatus.enAttente);
    expect(row.lastAttemptAt, isNotNull);
  });

  test('discard abandonne une mutation rejetée', () async {
    final id = await enqueueAt(DateTime.utc(2026, 9, 9, 10));
    await queue.applyResult(
      SyncResult(clientMutationId: id, status: SyncStatus.rejetee),
    );

    await queue.discard(id);

    expect(await queue.byStatus(LocalMutationStatus.rejetee), isEmpty);
  });

  test('toInputs produit exactement le corps attendu par POST /sync', () async {
    await enqueueAt(DateTime.utc(2026, 9, 9, 10), type: 'MANUAL');

    final inputs = await queue.toInputs(
      await queue.nextBatch(authorUserId: author),
    );

    expect(inputs, hasLength(1));
    final json = inputs.first.toJson();
    expect(
      json.keys,
      containsAll([
        'clientMutationId',
        'deviceId',
        'operationType',
        'payload',
        'deviceTimestamp',
      ]),
    );
    expect(json['operationType'], 'MANUAL');
    expect(json['payload'], {'quantity': '2.000'});
    // Le serveur exige de l'ISO 8601 en UTC.
    expect(json['deviceTimestamp'], '2026-09-09T10:00:00.000Z');
  });

  group('bornes offline', () {
    test('file vide = appareil sain', () async {
      expect(await queue.isTooStale(authorUserId: author), isFalse);
    });

    test('une mutation récente ne déclenche pas l’alerte', () async {
      await enqueueAt(DateTime.now().toUtc());
      expect(await queue.isTooStale(authorUserId: author), isFalse);
    });

    test('une mutation trop vieille déclenche l’alerte', () async {
      await enqueueAt(
        DateTime.now().toUtc().subtract(const Duration(hours: 96)),
      );
      expect(await queue.isTooStale(authorUserId: author), isTrue);
    });
  });

  group('auteur de la mutation (audit I2 — poste partagé)', () {
    test('chaque compte ne voit et n’envoie que SES mutations', () async {
      final mine = await enqueueAt(DateTime.utc(2026, 9, 9, 10));
      final theirs = await enqueueAt(
        DateTime.utc(2026, 9, 9, 9),
        authorUserId: 'compte-b',
      );

      expect(
        (await queue.nextBatch(
          authorUserId: author,
        )).map((m) => m.clientMutationId),
        [mine],
      );
      expect(
        (await queue.nextBatch(
          authorUserId: 'compte-b',
        )).map((m) => m.clientMutationId),
        [theirs],
      );
      expect(await queue.pendingCount(authorUserId: author), 1);
    });

    test('les mutations d’un autre compte sont comptées à part', () async {
      await enqueueAt(DateTime.utc(2026, 9, 9, 10));
      await enqueueAt(DateTime.utc(2026, 9, 9, 11), authorUserId: 'compte-b');
      await enqueueAt(DateTime.utc(2026, 9, 9, 12), authorUserId: 'compte-b');

      expect(
        await queue.watchForeignPendingCount(authorUserId: author).first,
        2,
      );
      expect(await queue.watchPendingCount(authorUserId: author).first, 1);
    });

    test('les rejets affichés sont ceux du compte connecté', () async {
      final theirs = await enqueueAt(
        DateTime.utc(2026, 9, 9, 10),
        authorUserId: 'compte-b',
      );
      await queue.applyResult(
        SyncResult(clientMutationId: theirs, status: SyncStatus.rejetee),
      );

      expect(await queue.watchRejected(authorUserId: author).first, isEmpty);
      expect(
        await queue.watchRejected(authorUserId: 'compte-b').first,
        hasLength(1),
      );
    });
  });
}
