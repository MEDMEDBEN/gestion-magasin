import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_api.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_models.dart';
import 'package:gestion_magasin/features/purchases/presentation/purchases_screen.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_api.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_models.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';
import 'support/fakes.dart';

PurchaseOrder _order(PurchaseStatus status) => PurchaseOrder(
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
      receivedQuantity: Decimal.zero,
      remainingQuantity: Decimal.fromInt(100),
      unitPriceHt: 120000,
      taxRate: '19.00',
      lineTotalHt: 12000000,
      lineTotalTtc: 14280000,
    ),
  ],
);

class _FakePurchasesApi extends PurchasesApi {
  _FakePurchasesApi(this.orders) : super(Dio());

  final List<PurchaseOrder> orders;
  Map<String, Object?>? created;
  (String, DateTime)? confirmed;

  @override
  Future<PurchaseOrderPage> list({int limit = 200}) async => PurchaseOrderPage(
    data: orders,
    meta: PageMeta(page: 1, limit: limit, total: orders.length),
  );

  @override
  Future<PurchaseOrder> create(Map<String, Object?> fields) async {
    created = fields;
    return _order(PurchaseStatus.draft);
  }

  @override
  Future<PurchaseOrder> confirm(String id, DateTime expectedUpdatedAt) async {
    confirmed = (id, expectedUpdatedAt);
    return _order(PurchaseStatus.confirmed);
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

AuthUser _admin() => authUser(
  id: 'a',
  roles: const ['ADMIN'],
  permissions: const ['purchase.create', 'purchase.confirm', 'supplier.read'],
);

AuthUser _magasinier() => authUser(
  id: 'm',
  roles: const ['MAGASINIER'],
  permissions: const ['purchase.create', 'supplier.read'],
);

Future<_FakePurchasesApi> _pump(
  WidgetTester tester,
  AuthUser user, {
  List<PurchaseOrder> orders = const [],
}) async {
  useScreenSize(tester, const Size(500, 1400));
  final api = _FakePurchasesApi(orders);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesApiProvider.overrideWithValue(api),
        suppliersApiProvider.overrideWithValue(_FakeSuppliersApi()),
        activeProductsProvider.overrideWith(
          (ref) => Stream.value([
            product(id: 'p1', name: 'Câble 3G2,5', sku: 'CAB-3G25'),
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
  return api;
}

void main() {
  testWidgets(
    'nouvelle commande : fournisseur, produit, quantité et prix partent au serveur',
    (tester) async {
      final api = await _pump(tester, _magasinier());

      await tester.tap(find.text('Nouvelle commande'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sonelec').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Câble 3G2,5 · CAB-3G25').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Quantité'),
        '12,5',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Prix d’achat HT'),
        '1200',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enregistrer la commande'));
      await tester.pumpAndSettle();

      expect(api.created, containsPair('supplierId', 's1'));
      expect(api.created!['lines'], [
        {'productId': 'p1', 'orderedQuantity': '12.500', 'unitPriceHt': 120000},
      ]);
      // Id généré côté client : un renvoi ne crée pas de doublon.
      expect(api.created!['id'], isA<String>());
    },
  );

  testWidgets('formulaire incomplet : rien n’est envoyé', (tester) async {
    final api = await _pump(tester, _magasinier());
    await tester.tap(find.text('Nouvelle commande'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer la commande'));
    await tester.pumpAndSettle();

    expect(find.text('Choisissez un fournisseur'), findsOneWidget);
    expect(api.created, isNull);
  });

  testWidgets('ADMIN confirme une commande envoyée', (tester) async {
    final api = await _pump(
      tester,
      _admin(),
      orders: [_order(PurchaseStatus.ordered)],
    );
    expect(find.textContaining('BC-2026-00007'), findsOneWidget);
    expect(find.text('Commandée'), findsOneWidget);

    await tester.tap(find.textContaining('BC-2026-00007'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmer la commande'));
    await tester.pumpAndSettle();

    // La version AFFICHÉE part avec la confirmation.
    expect(api.confirmed, ('o1', DateTime.utc(2026, 9, 16, 10, 30)));
  });

  testWidgets('MAGASINIER : ni confirmation ni annulation', (tester) async {
    await _pump(
      tester,
      _magasinier(),
      orders: [_order(PurchaseStatus.ordered)],
    );
    await tester.tap(find.textContaining('BC-2026-00007'));
    await tester.pumpAndSettle();

    expect(find.text('Modifier les lignes'), findsOneWidget);
    expect(find.text('Confirmer la commande'), findsNothing);
    expect(find.text('Annuler la commande'), findsNothing);
  });

  test('menu : « Achats » pour ADMIN/MAGASINIER, jamais le vendeur', () {
    expect(
      destinationsFor(_magasinier()).map((d) => d.label),
      contains('Achats'),
    );
    expect(
      destinationsFor(
        authUser(
          roles: const ['VENDEUR'],
          permissions: const ['purchase.create'],
        ),
      ).map((d) => d.label),
      isNot(contains('Achats')),
    );
  });
}
