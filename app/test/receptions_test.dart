import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_api.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_models.dart';
import 'package:gestion_magasin/features/purchases/presentation/purchases_screen.dart';
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

Future<_FakeReceptionsApi> _pump(
  WidgetTester tester,
  AuthUser user, {
  required List<PurchaseOrder> orders,
  List<Reception> receptionsDone = const [],
}) async {
  useScreenSize(tester, const Size(500, 1400));
  final receptions = _FakeReceptionsApi(existing: receptionsDone);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesApiProvider.overrideWithValue(_FakePurchasesApi(orders)),
        receptionsApiProvider.overrideWithValue(receptions),
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

void main() {
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
