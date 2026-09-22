import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/offline_write.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/mutation_queue.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_api.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_models.dart';
import 'package:gestion_magasin/features/purchases/presentation/purchases_screen.dart';
import 'package:gestion_magasin/features/receptions/application/receptions_controller.dart';
import 'package:gestion_magasin/features/receptions/data/receptions_api.dart';
import 'package:gestion_magasin/features/receptions/data/receptions_models.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_api.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_models.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';
import 'support/fakes.dart';

/// Réceptions (P0 n°7) côté app : le magasinier saisit ce qui est RÉELLEMENT
/// arrivé, sur une commande engagée, avec une clé d'idempotence stable.
PurchaseOrder _order(
  PurchaseStatus status, {
  String received = '0',
  String remaining = '100',
}) => PurchaseOrder(
  id: 'o1',
  number: 'BC-2026-00007',
  supplierId: 's1',
  status: status,
  orderDate: DateTime.utc(2026, 9, 16),
  totalHt: 12000000,
  totalTax: 2280000,
  totalTtc: 14280000,
  updatedAt: DateTime.utc(2026, 9, 16, 10, 30),
  lines: [
    PurchaseLine(
      id: 'l1',
      productId: 'p1',
      orderedQuantity: Decimal.fromInt(100),
      receivedQuantity: Decimal.parse(received),
      remainingQuantity: Decimal.parse(remaining),
      unitPriceHt: 120000,
      taxRate: '19.00',
      lineTotalHt: 12000000,
      lineTotalTtc: 14280000,
    ),
  ],
);

StorageLocation _location(String id, String type, String name) =>
    StorageLocation(
      id: id,
      code: type,
      name: name,
      type: type,
      isActive: true,
      updatedAt: DateTime.utc(2026, 9, 14),
    );

class _FakePurchasesApi extends PurchasesApi {
  _FakePurchasesApi(this.orders) : super(Dio());

  final List<PurchaseOrder> orders;
  (String, String)? closed;

  @override
  Future<PurchaseOrder> close(String id, String reason) async {
    closed = (id, reason);
    return _order(PurchaseStatus.closed);
  }

  @override
  Future<PurchaseOrderPage> list({int limit = 200}) async => PurchaseOrderPage(
    data: orders,
    meta: PageMeta(page: 1, limit: limit, total: orders.length),
  );
}

class _FakeReceptionsApi extends ReceptionsApi {
  _FakeReceptionsApi({this.existing = const []}) : super(Dio());

  final List<Reception> existing;
  final List<Map<String, Object?>> sent = [];

  @override
  Future<List<Reception>> list({
    String? purchaseOrderId,
    int limit = 50,
  }) async => existing;

  @override
  Future<Reception> create(Map<String, Object?> fields) async {
    sent.add(fields);
    return Reception(
      id: 'r1',
      number: 'BR-2026-00001',
      purchaseOrderId: 'o1',
      supplierId: 's1',
      locationId: 'depot',
      receivedAt: DateTime.utc(2026, 9, 20),
      totalTtc: 9996000,
      lines: const [],
    );
  }
}

class _FakeSuppliersApi extends SuppliersApi {
  _FakeSuppliersApi() : super(Dio());

  @override
  Future<SupplierPage> list({
    String? query,
    bool includeInactive = false,
  }) async => const SupplierPage(
    data: [
      Supplier(
        id: 's1',
        name: 'Sonelec',
        openingBalance: 0,
        paidAmount: 0,
        balanceDue: 0,
        isActive: true,
      ),
    ],
    meta: PageMeta(page: 1, limit: 200, total: 1),
  );
}

AuthUser _magasinier({
  List<String> permissions = const [
    'purchase.create',
    'reception.create',
    'supplier.read',
  ],
}) => authUser(id: 'm', roles: const ['MAGASINIER'], permissions: permissions);

late _FakePurchasesApi _lastPurchases;

Future<_FakeReceptionsApi> _pump(
  WidgetTester tester,
  AuthUser user, {
  required List<PurchaseOrder> orders,
  List<Reception> receptionsDone = const [],
}) async {
  useScreenSize(tester, const Size(500, 1400));
  final receptions = _FakeReceptionsApi(existing: receptionsDone);
  _lastPurchases = _FakePurchasesApi(orders);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesApiProvider.overrideWithValue(_lastPurchases),
        receptionsApiProvider.overrideWithValue(receptions),
        // Une écriture (en ligne ou en file) appartient au compte connecté.
        currentUserIdProvider.overrideWithValue('magasinier'),
        suppliersApiProvider.overrideWithValue(_FakeSuppliersApi()),
        activeProductsProvider.overrideWith(
          (ref) => Stream.value([
            product(id: 'p1', name: 'Câble 3G2,5', sku: 'CAB-3G25'),
          ]),
        ),
        locationsProvider.overrideWith(
          (ref) => Stream.value([
            _location('magasin', 'MAGASIN', 'Magasin'),
            _location('depot', 'DEPOT', 'Dépôt'),
          ]),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: PurchasesScreen(user: user)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return receptions;
}

Future<void> _openReceptionForm(WidgetTester tester) async {
  await tester.tap(find.textContaining('BC-2026-00007'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Réceptionner la marchandise'));
  await tester.pumpAndSettle();
}

class _OfflineReceptionsApi extends ReceptionsApi {
  _OfflineReceptionsApi() : super(Dio());

  @override
  Future<Reception> create(Map<String, Object?> fields) async =>
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

void main() {
  test(
    'sans réseau : la réception part dans la file (même clé, id de l’appareil), '
    'jamais présentée comme faite',
    () async {
      final queue = _RecordingQueue();
      final container = ProviderContainer(
        overrides: [
          receptionsApiProvider.overrideWithValue(_OfflineReceptionsApi()),
          currentUserIdProvider.overrideWithValue('magasinier'),
          deviceIdProvider.overrideWith((ref) async => 'poste-depot'),
          mutationQueueProvider.overrideWithValue(queue),
        ],
      );
      addTearDown(container.dispose);

      final outcome = await container
          .read(receptionsActionsProvider)
          .receive(
            intent: 'reception:formulaire-1',
            purchaseOrderId: 'o1',
            supplierId: 's1',
            locationId: 'depot',
            lines: [
              (
                productId: 'p1',
                purchaseLineId: 'l1',
                receivedQuantity: Decimal.fromInt(4),
                unitPriceHt: 120000,
              ),
            ],
          );

      expect(outcome, isA<Queued<Reception>>());
      final queued = queue.queued.single;
      expect(queued.type, 'RECEPTION');
      expect(queued.payload['clientMutationId'], queued.key);
      expect(queued.payload['id'], queued.key);
      expect(queued.payload['lines'], [
        {
          'productId': 'p1',
          'purchaseLineId': 'l1',
          'receivedQuantity': '4.000',
          'unitPriceHt': 120000,
        },
      ]);
    },
  );

  testWidgets(
    'le reste à recevoir est pré-rempli et part avec une clé d’idempotence',
    (tester) async {
      final api = await _pump(
        tester,
        _magasinier(),
        orders: [
          _order(
            PurchaseStatus.partiallyReceived,
            received: '30',
            remaining: '70',
          ),
        ],
      );
      await _openReceptionForm(tester);

      // Le champ propose le reste à recevoir, pas la quantité commandée.
      expect(find.text('70'), findsOneWidget);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dépôt').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enregistrer la réception'));
      await tester.pumpAndSettle();

      final sent = api.sent.single;
      expect(sent['purchaseOrderId'], 'o1');
      expect(sent['locationId'], 'depot');
      expect(sent['clientMutationId'], isA<String>());
      expect(sent['lines'], [
        {
          'productId': 'p1',
          'purchaseLineId': 'l1',
          'receivedQuantity': '70.000',
          'unitPriceHt': 120000,
        },
      ]);
    },
  );

  testWidgets('surlivraison bloquée avant l’envoi', (tester) async {
    final api = await _pump(
      tester,
      _magasinier(),
      orders: [_order(PurchaseStatus.confirmed)],
    );
    await _openReceptionForm(tester);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dépôt').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantité reçue'),
      '101',
    );
    await tester.tap(find.text('Enregistrer la réception'));
    await tester.pumpAndSettle();

    expect(find.text('Au plus 100'), findsOneWidget);
    expect(api.sent, isEmpty);
  });

  testWidgets('emplacement obligatoire : rien n’est envoyé sans lui', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _magasinier(),
      orders: [_order(PurchaseStatus.confirmed)],
    );
    await _openReceptionForm(tester);
    await tester.tap(find.text('Enregistrer la réception'));
    await tester.pumpAndSettle();

    expect(find.text('Choisissez un emplacement'), findsOneWidget);
    expect(api.sent, isEmpty);
  });

  testWidgets('la liste des réceptions d’une commande s’affiche vraiment', (
    tester,
  ) async {
    await _pump(
      tester,
      _magasinier(),
      orders: [_order(PurchaseStatus.partiallyReceived, remaining: '70')],
      receptionsDone: [
        Reception(
          id: 'r1',
          number: 'BR-2026-00001',
          purchaseOrderId: 'o1',
          supplierId: 's1',
          locationId: 'depot',
          receivedAt: DateTime.utc(2026, 9, 20),
          totalTtc: 9996000,
          lines: [
            ReceptionLine(
              id: 'rl1',
              productId: 'p1',
              purchaseLineId: 'l1',
              receivedQuantity: Decimal.fromInt(30),
              unitPriceHt: 120000,
              lineTotalHt: 3600000,
              lineTotalTtc: 4284000,
            ),
          ],
        ),
      ],
    );
    await tester.tap(find.textContaining('BC-2026-00007'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Réceptions enregistrées'));
    await tester.pumpAndSettle();

    expect(find.text('BR-2026-00001'), findsOneWidget);
    // Le montant est bien FORMATÉ, pas affiché comme du code.
    // Le bon de réception, pas seulement la commande derrière le dialogue.
    expect(find.textContaining('960,00 DA TTC'), findsOneWidget);
    expect(find.textContaining('ligne(s)'), findsNWidgets(2));
    expect(find.textContaining(r'${'), findsNothing);
  });

  testWidgets('clôture du reliquat : ADMIN seul, motif obligatoire', (
    tester,
  ) async {
    // Le magasinier ne voit pas l'action.
    await _pump(
      tester,
      _magasinier(),
      orders: [_order(PurchaseStatus.partiallyReceived, remaining: '70')],
    );
    await tester.tap(find.textContaining('BC-2026-00007'));
    await tester.pumpAndSettle();
    expect(find.text('Clôturer le reliquat'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await _pump(
      tester,
      authUser(
        id: 'a',
        roles: const ['ADMIN'],
        permissions: const [
          'purchase.create',
          'purchase.confirm',
          'reception.create',
          'supplier.read',
        ],
      ),
      orders: [_order(PurchaseStatus.partiallyReceived, remaining: '70')],
    );
    await tester.tap(find.textContaining('BC-2026-00007'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clôturer le reliquat'));
    await tester.pumpAndSettle();

    // Sans motif, rien ne part.
    await tester.tap(find.widgetWithText(FilledButton, 'Clôturer'));
    await tester.pumpAndSettle();
    expect(
      find.text('Indiquez le motif (3 caractères minimum)'),
      findsOneWidget,
    );
    expect(_lastPurchases.closed, isNull);

    await tester.enterText(find.byType(TextField), 'Rupture définitive');
    await tester.tap(find.widgetWithText(FilledButton, 'Clôturer'));
    await tester.pumpAndSettle();
    expect(_lastPurchases.closed, ('o1', 'Rupture définitive'));
  });

  testWidgets('commande brouillon : aucune réception proposée', (tester) async {
    await _pump(tester, _magasinier(), orders: [_order(PurchaseStatus.draft)]);
    await tester.tap(find.textContaining('BC-2026-00007'));
    await tester.pumpAndSettle();

    expect(find.text('Réceptionner la marchandise'), findsNothing);
  });

  testWidgets('sans le droit reception.create : action absente', (
    tester,
  ) async {
    await _pump(
      tester,
      _magasinier(permissions: const ['purchase.create', 'supplier.read']),
      orders: [_order(PurchaseStatus.confirmed)],
    );
    await tester.tap(find.textContaining('BC-2026-00007'));
    await tester.pumpAndSettle();

    expect(find.text('Réceptionner la marchandise'), findsNothing);
  });
}
