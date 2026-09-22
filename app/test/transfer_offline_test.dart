import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/offline_write.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/data/local/mutation_queue.dart';
import 'package:gestion_magasin/features/transfers/application/transfers_controller.dart';
import 'package:gestion_magasin/features/transfers/data/transfers_api.dart';
import 'package:gestion_magasin/features/transfers/data/transfers_models.dart';

class _OfflineTransfersApi extends TransfersApi {
  _OfflineTransfersApi() : super(Dio());
  final online = <String>[];

  @override
  Future<Transfer> ship(String id) async {
    online.add('ship:$id');
    throw const ApiException(statusCode: 0, message: 'hors ligne');
  }
}

class _RecordingQueue implements MutationQueue {
  _RecordingQueue({this.transferPending = false});

  final bool transferPending;
  final queued = <({String type, Map<String, dynamic> payload, String? key})>[];

  @override
  Future<bool> isTooStale({required String authorUserId}) async => false;

  @override
  Future<PendingMutation?> latestPending({
    required String authorUserId,
    required String operationType,
  }) async => transferPending
      ? PendingMutation(
          clientMutationId: 'deja',
          authorUserId: authorUserId,
          deviceId: 'poste',
          operationType: operationType,
          payload: '{}',
          deviceTimestamp: DateTime.utc(2026, 9, 22),
          status: LocalMutationStatus.enAttente,
          attemptCount: 0,
          createdAt: DateTime.utc(2026, 9, 22),
        )
      : null;

  @override
  Future<String> enqueue({
    required String authorUserId,
    required String deviceId,
    required String operationType,
    required Map<String, dynamic> payload,
    String? clientMutationId,
    DateTime? deviceTimestamp,
  }) async {
    queued.add((type: operationType, payload: payload, key: clientMutationId));
    return clientMutationId!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

({ProviderContainer container, _OfflineTransfersApi api}) _setUp(
  _RecordingQueue queue,
) {
  final api = _OfflineTransfersApi();
  final container = ProviderContainer(
    overrides: [
      transfersApiProvider.overrideWithValue(api),
      currentUserIdProvider.overrideWithValue('magasinier'),
      deviceIdProvider.overrideWith((ref) async => 'poste-depot'),
      mutationQueueProvider.overrideWithValue(queue),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, api: api);
}

void main() {
  test('expédition sans réseau : l’étape part dans la file, jamais '
      'présentée comme faite', () async {
    final queue = _RecordingQueue();
    final setup = _setUp(queue);

    final outcome = await setup.container
        .read(transfersActionsProvider)
        .ship('t1');

    expect(outcome, isA<Queued<Transfer>>());
    final queued = queue.queued.single;
    expect(queued.type, 'TRANSFER');
    expect(queued.payload, {
      'action': 'SHIP',
      'clientMutationId': queued.key,
      'transferId': 't1',
    });
    expect(transferOutcomeText(outcome), contains('pas encore fait'));
  });

  test('étapes de transfert déjà en file : la suivante passe DERRIÈRE elles, '
      'sans essai en ligne', () async {
    final queue = _RecordingQueue(transferPending: true);
    final setup = _setUp(queue);

    await setup.container.read(transfersActionsProvider).ship('t1');

    expect(setup.api.online, isEmpty);
    expect(queue.queued.single.payload['action'], 'SHIP');
  });
}
