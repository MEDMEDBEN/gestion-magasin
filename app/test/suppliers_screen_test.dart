import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/file_export.dart';
import 'package:gestion_magasin/core/money.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_api.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_models.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_api.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_models.dart';
import 'package:gestion_magasin/features/suppliers/presentation/suppliers_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';
import 'support/fakes.dart';

class _FakeSuppliersApi extends SuppliersApi {
  final returnsSent = <Map<String, Object?>>[];

  @override
  Future<Map<String, dynamic>> returnGoods(Map<String, Object?> body) async {
    returnsSent.add(body);
    return {'id': 'rf1', 'number': 'RF-2026-00001', 'totalTtc': 428400};
  }

  _FakeSuppliersApi() : super(Dio());

  Map<String, Object?>? payment;
  final List<String> keys = [];

  /// Nombre d'échecs réseau à simuler avant d'accepter le paiement.
  int failuresBeforeSuccess = 0;
  Map<String, Object?>? saved;

  final _suppliers = [
    const Supplier(
      id: 's1',
      name: 'Sonelec',
      phone: '0550 11 22 33',
      contactName: 'M. Rahmani',
      openingBalance: 500000,
      paidAmount: 200000,
      balanceDue: 300000,
      isActive: true,
    ),
    const Supplier(
      id: 's2',
      name: 'Câbles du Sud',
      openingBalance: 0,
      paidAmount: 0,
      balanceDue: 0,
      isActive: true,
    ),
  ];

  @override
  Future<SupplierPage> list({
    String? query,
    bool includeInactive = false,
  }) async {
    final match = query == null
        ? _suppliers
        : _suppliers
              .where((s) => s.name.toLowerCase().contains(query.toLowerCase()))
              .toList();
    return SupplierPage(
      data: match,
      meta: PageMeta(page: 1, limit: 200, total: match.length),
    );
  }

  @override
  Future<SupplierPayment> pay(Map<String, Object?> fields) async {
    payment = fields;
    keys.add(fields['clientMutationId']! as String);
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      // Délai dépassé : on ne sait pas si le serveur a appliqué le paiement.
      throw const ApiException(statusCode: 0, message: 'Délai dépassé');
    }
    final amount = fields['amount']! as int;
    return SupplierPayment(
      id: fields['clientMutationId']! as String,
      supplierId: fields['supplierId']! as String,
      amount: amount,
      method: fields['fromCash'] == true ? 'ESPECES' : 'VIREMENT',
      fromCash: fields['fromCash']! as bool,
      paidAt: DateTime.utc(2026, 9, 16),
      balanceDue: 300000 - amount,
    );
  }

  @override
  Future<Supplier> create(Map<String, Object?> fields) async {
    saved = fields;
    return _suppliers.first;
  }

  @override
  Future<SupplierStats> stats(String supplierId) async => SupplierStats(
    productCount: 4,
    deliveriesWithDate: 4,
    deliveriesOnTime: 3,
    prices: [
      SupplierProductPrice(
        productId: 'p1',
        name: 'Disjoncteur',
        sku: 'DIS-16A',
        receptions: 3,
        firstPriceHt: 100000,
        previousPriceHt: 110000,
        lastPriceHt: 115000,
        lastReceivedAt: DateTime.utc(2026, 9, 20, 10),
      ),
    ],
  );

  final exports = <String>[];

  @override
  Future<ExportedFile> exportSuppliers(
    ExportFormat format, {
    bool debtOnly = false,
  }) async {
    exports.add('${format.name} debtOnly=$debtOnly');
    return ExportedFile(Uint8List(1), 'dettes-fournisseurs.${format.name}');
  }
}

/// Commandes du fournisseur : le filtre part au SERVEUR.
class _FakePurchasesApi extends PurchasesApi {
  _FakePurchasesApi() : super(Dio());

  final asked = <String?>[];

  @override
  Future<PurchaseOrderPage> list({int limit = 200, String? supplierId}) async {
    asked.add(supplierId);
    final order = PurchaseOrder(
      id: 'po1',
      number: 'CMD-2026-00007',
      supplierId: 's1',
      status: PurchaseStatus.confirmed,
      orderDate: DateTime(2026, 9, 20),
      totalHt: 100000,
      totalTax: 19000,
      totalTtc: 119000,
      updatedAt: DateTime(2026, 9, 20),
      lines: const [],
    );
    return PurchaseOrderPage(
      data: [order],
      meta: PageMeta(page: 1, limit: limit, total: 1),
    );
  }
}

AuthUser _admin({bool purchases = true}) => authUser(
  id: 'a',
  roles: const ['ADMIN'],
  permissions: [
    'supplier.read',
    'supplier.write',
    'supplier.payment.create',
    if (purchases) 'purchase.create',
    if (purchases) 'reception.create',
  ],
);

final _purchases = _FakePurchasesApi();

Future<_FakeSuppliersApi> _pump(WidgetTester tester, AuthUser user) async {
  useScreenSize(tester, const Size(500, 1000));
  final api = _FakeSuppliersApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        suppliersApiProvider.overrideWithValue(api),
        purchasesApiProvider.overrideWithValue(_purchases),
        activeProductsProvider.overrideWith(
          (ref) => Stream.value([product(id: 'p1', name: 'Disjoncteur')]),
        ),
        locationsProvider.overrideWith(
          (ref) => Stream.value([
            StorageLocation(
              id: 'depot',
              code: 'DEP',
              name: 'Dépôt',
              type: 'DEPOT',
              isActive: true,
              updatedAt: DateTime.utc(2026),
            ),
          ]),
        ),
        saveExportProvider.overrideWithValue(
          (file) async => 'C:/Téléchargements/${file.filename}',
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: SuppliersScreen(user: user)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  /// Le vendeur n'accède pas à cet écran ; ici, l'export des dettes demande
  /// bien le filtre au SERVEUR, qui applique la garde de la liste.
  testWidgets('export des dettes fournisseurs : filtre demandé au serveur', (
    tester,
  ) async {
    final api = await _pump(tester, _admin());

    await tester.tap(find.byTooltip('Exporter'));
    await tester.pumpAndSettle();
    // Un seul bouton : le menu dit QUOI avant de dire le format.
    expect(find.text('Fournisseurs'), findsWidgets);
    expect(find.text('Dettes fournisseurs'), findsOneWidget);
    await tester.tap(find.text('   CSV').last);
    await tester.pumpAndSettle();

    expect(api.exports, ['csv debtOnly=true']);
    expect(
      find.text(
        'Enregistré sur ce poste : C:/Téléchargements/dettes-fournisseurs.csv',
      ),
      findsOneWidget,
    );
  });

  testWidgets('liste : dette affichée, « à jour » sans dette', (tester) async {
    await _pump(tester, _admin());

    expect(find.text('Sonelec'), findsOneWidget);
    expect(find.text('Dette ${formatDA(300000)}'), findsOneWidget);
    expect(find.text('À jour'), findsOneWidget);
  });

  testWidgets('paiement hors caisse : montant et choix envoyés au serveur', (
    tester,
  ) async {
    final api = await _pump(tester, _admin());

    await tester.tap(find.text('Sonelec'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer un paiement'));
    await tester.pumpAndSettle();

    // Le dialogue propose le reste dû ; le paiement part hors caisse.
    expect(
      find.widgetWithText(TextField, formatDA(300000, withSymbol: false)),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField).last, '1000');
    await tester.tap(find.text('Payé depuis la caisse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    expect(api.payment, containsPair('amount', 100000));
    expect(api.payment, containsPair('fromCash', false));
    expect(api.payment, containsPair('supplierId', 's1'));
    expect(find.textContaining('reste dû'), findsOneWidget);
  });

  testWidgets(
    'délai dépassé puis nouvel essai (dialogue rouvert) : MÊME clé, jamais un second paiement',
    (tester) async {
      final api = await _pump(tester, _admin());
      api.failuresBeforeSuccess = 1;

      Future<void> payOnce() async {
        await tester.tap(find.text('Sonelec'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Enregistrer un paiement'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, '1000');
        await tester.tap(find.text('Enregistrer'));
        await tester.pumpAndSettle();
      }

      await payOnce(); // échoue (réseau)
      await payOnce(); // l'utilisateur réessaie
      expect(api.keys, hasLength(2));
      expect(api.keys.toSet(), hasLength(1));

      await payOnce(); // paiement suivant, confirmé : NOUVELLE opération
      expect(api.keys.last, isNot(api.keys.first));
    },
  );

  testWidgets('paiement refusé au-delà du reste dû (avant tout appel)', (
    tester,
  ) async {
    final api = await _pump(tester, _admin());

    await tester.tap(find.text('Sonelec'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer un paiement'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '9999');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    expect(find.text('Au-delà du reste dû'), findsOneWidget);
    expect(api.payment, isNull);
  });

  /// Miroir de `POST /imports/suppliers` : ADMIN + supplier.write.
  testWidgets('import : proposé à l’admin', (tester) async {
    await _pump(tester, _admin());
    expect(find.byTooltip('Importer'), findsOneWidget);
  });

  testWidgets('MAGASINIER : lecture seule, ni création ni paiement', (
    tester,
  ) async {
    await _pump(
      tester,
      authUser(
        id: 'm',
        roles: const ['MAGASINIER'],
        permissions: const ['supplier.read'],
      ),
    );

    expect(find.text('Nouveau'), findsNothing);
    await tester.tap(find.text('Sonelec'));
    await tester.pumpAndSettle();
    expect(find.text('Enregistrer un paiement'), findsNothing);
    expect(find.text('Modifier la fiche'), findsNothing);
    expect(find.byTooltip('Importer'), findsNothing);
  });

  test('menu : « Fournisseurs » pour ADMIN/MAGASINIER, jamais le vendeur', () {
    expect(
      destinationsFor(_admin()).map((d) => d.label),
      contains('Fournisseurs'),
    );
    expect(
      destinationsFor(
        authUser(
          roles: const ['VENDEUR'],
          // Même avec la permission posée en base, le rôle ferme la porte.
          permissions: const ['supplier.read'],
        ),
      ).map((d) => d.label),
      isNot(contains('Fournisseurs')),
    );
  });

  /// Retour de test humain (2026-09-27) : l'historique des achats d'un
  /// fournisseur était introuvable.
  testWidgets('fiche fournisseur : historique des achats, filtré serveur', (
    tester,
  ) async {
    await _pump(tester, _admin());
    await tester.tap(find.text('Sonelec'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Historique des achats'));
    await tester.pumpAndSettle();

    expect(_purchases.asked.last, 's1');
    expect(find.text('CMD-2026-00007 · Confirmée'), findsOneWidget);
    expect(find.text('${formatDA(119000)} TTC'), findsOneWidget);
  });

  testWidgets('sans le droit de lire les achats : pas d’historique proposé', (
    tester,
  ) async {
    await _pump(tester, _admin(purchases: false));
    await tester.tap(find.text('Sonelec'));
    await tester.pumpAndSettle();
    expect(find.text('Historique des achats'), findsNothing);
  });

  /// P1 bis n°21l : retour de marchandise depuis la fiche fournisseur.
  testWidgets('retour de marchandise : produit, quantité, dépôt, motif', (
    tester,
  ) async {
    final api = await _pump(tester, _admin());
    await tester.tap(find.text('Sonelec'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Retour de marchandise'));
    await tester.tap(find.text('Retour de marchandise'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Produit'));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Disjoncteur').last);
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '3');
    await tester.enterText(fields.at(1), 'Lot défectueux');
    await tester.tap(find.text('Enregistrer le retour'));
    await tester.pumpAndSettle();
    final sent = api.returnsSent.single;
    expect(sent['supplierId'], 's1');
    expect(sent['locationId'], 'depot');
    expect(sent['lines'], [
      {'productId': 'p1', 'quantity': '3.000'},
    ]);
    expect(sent['clientMutationId'], isA<String>());
    expect(find.textContaining('RF-2026-00001'), findsOneWidget);
  });

  /// P1 bis n°21m : indicateurs fournisseur (magasinier compris).
  testWidgets('indicateurs : total acheté, produits, ponctualité, prix', (
    tester,
  ) async {
    await _pump(
      tester,
      authUser(
        id: 'm',
        roles: const ['MAGASINIER'],
        permissions: const ['supplier.read'],
      ),
    );
    await tester.tap(find.text('Sonelec'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Indicateurs'));
    await tester.pumpAndSettle();

    expect(find.text('Produits fournis'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('75 %'), findsOneWidget);
    expect(find.text('DIS-16A — Disjoncteur'), findsOneWidget);
    expect(find.text('${formatDA(115000)} HT (+4,5 %)'), findsOneWidget);
  });

  test('évolution du prix d’achat', () {
    expect(priceEvolution(null, 100000), '');
    expect(priceEvolution(0, 100000), '');
    expect(priceEvolution(100000, 100000), '');
    expect(priceEvolution(100000, 99999), '');
    expect(priceEvolution(110000, 99000), ' (-10,0 %)');
  });

  testWidgets('sans le droit de réception : pas de retour proposé', (
    tester,
  ) async {
    await _pump(tester, _admin(purchases: false));
    await tester.tap(find.text('Sonelec'));
    await tester.pumpAndSettle();
    expect(find.text('Retour de marchandise'), findsNothing);
  });
}
