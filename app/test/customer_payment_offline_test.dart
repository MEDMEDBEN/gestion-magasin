import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/offline_write.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/mutation_queue.dart';
import 'package:gestion_magasin/features/sales/application/sales_controller.dart';
import 'package:gestion_magasin/features/sales/data/sales_api.dart';
import 'package:gestion_magasin/features/sales/data/sales_models.dart';

class _OfflineSalesApi extends SalesApi {
  _OfflineSalesApi() : super(Dio());

  @override
  Future<void> payCustomer(Map<String, dynamic> body) async =>
      throw const ApiException(statusCode: 0, message: 'hors ligne');
}

class _RecordingQueue implements MutationQueue {
  final queued = <({String type, Map<String, dynamic> payload, String? key})>[];

  @override
  Future<bool> isTooStale({required String authorUserId}) async => false;

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

CashSession _cash(String status) => CashSession(
  id: 'caisse-1',
  status: status,
  openingFloat: 0,
  cashSalesAmount: 0,
  cashSalesCount: 0,
  currentAmount: 0,
  openedAt: DateTime.utc(2026, 9, 22, 8),
);

ProviderContainer _container(_RecordingQueue queue, CashSession? cash) {
  final container = ProviderContainer(
    overrides: [
      salesApiProvider.overrideWithValue(_OfflineSalesApi()),
      currentUserIdProvider.overrideWithValue('vendeur'),
      deviceIdProvider.overrideWith((ref) async => 'poste-caisse'),
      mutationQueueProvider.overrideWithValue(queue),
      currentCashSessionProvider.overrideWith((ref) async => cash),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('sans réseau : le règlement part dans la file avec SA caisse, '
      'jamais présenté comme encaissé', () async {
    final queue = _RecordingQueue();
    final container = _container(queue, _cash('OUVERTE'));
    await container.read(currentCashSessionProvider.future);

    final outcome = await container
        .read(salesActionsProvider)
        .payCustomer('client-1', 50000);

    expect(outcome, isA<Queued<void>>());
    final queued = queue.queued.single;
    expect(queued.type, 'CUSTOMER_PAYMENT');
    expect(queued.payload, {
      'clientMutationId': queued.key,
      'id': queued.key,
      'customerId': 'client-1',
      'amount': 50000,
      'cashSessionId': 'caisse-1',
    });
  });

  test(
    'caisse inconnue ou fermée : aucun règlement, même mis en file',
    () async {
      final queue = _RecordingQueue();
      final container = _container(queue, null);
      await container.read(currentCashSessionProvider.future);

      await expectLater(
        container.read(salesActionsProvider).payCustomer('client-1', 50000),
        throwsA(isA<ApiException>()),
      );
      expect(queue.queued, isEmpty);
    },
  );
}
