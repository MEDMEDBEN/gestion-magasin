import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/purchases/application/purchases_controller.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_api.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_models.dart';
import 'package:gestion_magasin/features/purchases/presentation/purchases_screen.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_api.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_models.dart';
import 'package:gestion_magasin/features/sales/application/sales_controller.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/core/photos.dart';
import 'package:gestion_magasin/features/receptions/data/receptions_api.dart';
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
  Future<PurchaseOrderPage> list({int limit = 200, String? supplierId}) async =>
      PurchaseOrderPage(
        data: orders,
        meta: PageMeta(page: 1, limit: limit, total: orders.length),
      );

  @override
  Future<PurchaseOrder> create(Map<String, Object?> fields) async {
    created = fields;
    return _order(PurchaseStatus.draft);
  }

  Map<String, Object?>? updated;

  @override
  Future<PurchaseOrder> update(String id, Map<String, Object?> fields) async {
    updated = fields;
    return _order(PurchaseStatus.draft);
  }

  @override
  Future<PurchaseOrder> confirm(String id, DateTime expectedUpdatedAt) async {
    confirmed = (id, expectedUpdatedAt);
    return _order(PurchaseStatus.confirmed);
  }

  final documents = <String>[];

  @override
  Future<Uint8List> document(String id) async {
    documents.add(id);
    return Uint8List(4);
  }

  @override
  Future<Map<String, dynamic>> message(String id) async => {
    'text': 'Bonjour,\nNous souhaitons commander :\n- 10 pce de Disjoncteur',
    'supplierName': 'Sonelec',
    'email': 'achats@sonelec.dz',
    'phone': null,
  };
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
        printPdfProvider.overrideWithValue((bytes, name) async {
          printedPdfs.add(name);
        }),
        currentUserIdProvider.overrideWithValue('u'),
        documentCacheProvider.overrideWithValue(MemoryDocumentCache()),
        suppliersApiProvider.overrideWithValue(_FakeSuppliersApi()),
        receptionsApiProvider.overrideWithValue(_ScanningReceptionsApi()),
        pickDocumentPhotoProvider.overrideWithValue(
          () async => Uint8List.fromList([1, 2, 3]),
        ),
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

/// Lecture de facture (P2 n°24) : une ligne reconnue, une inconnue.
class _ScanningReceptionsApi extends ReceptionsApi {
  _ScanningReceptionsApi() : super(Dio());

  @override
  Future<List<Map<String, dynamic>>> scanInvoice(Uint8List jpeg) async => [
    {
      'text': 'CAB-3G25 Cable 3G2,5 40 1 150,00 46 000,00',
      'productId': 'p1',
      'productName': 'Câble 3G2,5',
      'quantity': '40.000',
      'unitPriceHt': 115000,
    },
    {
      'text': 'Gaine ICTA 20 5 35,00 175,00',
      'productId': null,
      'productName': null,
      'quantity': '5.000',
      'unitPriceHt': 3500,
    },
  ];
}

final printedPdfs = <String>[];

void main() {
  setUp(printedPdfs.clear);

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

  /// P2 n°24 : la facture lue remplit la ligne vide ; on vérifie, puis on
  /// enregistre par le chemin habituel.
  testWidgets('nouvelle commande remplie depuis une facture', (tester) async {
    final api = await _pump(tester, _magasinier());
    await tester.tap(find.text('Nouvelle commande'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sonelec').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remplir depuis une facture'));
    await tester.pumpAndSettle();
    expect(find.text('Gaine ICTA 20 5 35,00 175,00'), findsOneWidget);
    await tester.tap(find.text('Vérifier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer la commande'));
    await tester.pumpAndSettle();
    expect(api.created!['lines'], [
      {'productId': 'p1', 'orderedQuantity': '40.000', 'unitPriceHt': 115000},
    ]);
  });

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

  testWidgets('bon de commande : imprimé depuis la commande', (tester) async {
    final api = await _pump(
      tester,
      _admin(),
      orders: [_order(PurchaseStatus.ordered)],
    );
    await tester.tap(find.textContaining('BC-2026-00007'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Imprimer le bon de commande'));
    await tester.pumpAndSettle();
    expect(api.documents, ['o1']);
    expect(printedPdfs, ['BC-2026-00007.pdf']);
  });

  /// P2 n°22 : message à modèle fixe, copié pour l'e-mail ou WhatsApp.
  testWidgets('message au fournisseur : affiché puis copié', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await _pump(tester, _admin(), orders: [_order(PurchaseStatus.ordered)]);
    await tester.tap(find.textContaining('BC-2026-00007'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message au fournisseur'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nous souhaitons commander'), findsOneWidget);
    expect(find.text('E-mail : achats@sonelec.dz'), findsOneWidget);
    await tester.tap(find.text('Copier le message'));
    await tester.pumpAndSettle();
    expect(copied, contains('10 pce de Disjoncteur'));
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

  /// P1 bis n°21i : livraison prévue (retard fournisseur) et échéance de
  /// paiement, en jours locaux ; en modification, `null` efface la date.
  test('commande : dates envoyées en jours, effacées par null', () async {
    final api = _FakePurchasesApi(const []);
    final container = ProviderContainer(
      overrides: [
        purchasesApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue('a'),
      ],
    );
    addTearDown(container.dispose);
    final actions = container.read(purchasesActionsProvider);
    final lines = [
      (productId: 'p1', quantity: Decimal.one, unitPriceHt: 100000),
    ];
    await actions.save(
      id: 'po1',
      isNew: true,
      supplierId: 's1',
      lines: lines,
      expectedDate: DateTime(2026, 10, 5),
      dueDate: DateTime(2026, 11, 5),
    );
    expect(api.created!['expectedDate'], '2026-10-05');
    expect(api.created!['dueDate'], '2026-11-05');

    await actions.save(id: 'po1', isNew: false, supplierId: 's1', lines: lines);
    expect(api.updated!.containsKey('expectedDate'), isTrue);
    expect(api.updated!['expectedDate'], isNull);
    expect(api.updated!['dueDate'], isNull);
    // La note n'est pas effacée par une modification qui ne la porte pas.
    expect(api.updated!.containsKey('note'), isFalse);

    // Commande engagée : seules les dates partent (nouveau délai).
    await actions.setDates('po1', expectedDate: DateTime(2026, 12, 15));
    expect(api.updated, {'expectedDate': '2026-12-15', 'dueDate': null});
  });
}
