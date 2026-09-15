import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/stock/application/stock_controller.dart';
import 'package:gestion_magasin/features/stock/data/stock_api.dart';
import 'package:gestion_magasin/features/stock/data/stock_models.dart';
import 'package:gestion_magasin/features/stock/presentation/stock_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';
import 'support/fakes.dart';

StorageLocation _location(String id, String type, String name) =>
    StorageLocation(
      id: id,
      code: type,
      name: name,
      type: type,
      isActive: true,
      updatedAt: DateTime.utc(2026, 9, 14),
    );

StockLevel _level(String productId, String locationId, String quantity) =>
    StockLevel(
      productId: productId,
      locationId: locationId,
      quantity: Decimal.parse(quantity),
      reservedQuantity: Decimal.zero,
      inTransitQuantity: Decimal.zero,
      availableQuantity: Decimal.parse(quantity),
    );

StockLoss _loss({
  String id = 'l1',
  StockLossStatus status = StockLossStatus.pending,
}) => StockLoss(
  id: id,
  productId: 'p1',
  locationId: 'depot',
  quantity: Decimal.parse('2'),
  comment: 'Carton écrasé',
  status: status,
  declaredById: 'm',
  createdAt: DateTime.utc(2026, 9, 14, 9),
);

/// Faux client : enregistre ce qui part au serveur.
class _RecordingStockApi extends StockApi {
  _RecordingStockApi() : super(Dio());

  final List<String> calls = [];
  Map<String, Object?>? declared;

  @override
  Future<StockLossPage> losses({
    StockLossStatus? status,
    int limit = 200,
  }) async => StockLossPage(
    data: [_loss()],
    meta: const PageMeta(page: 1, limit: 200, total: 1),
  );

  @override
  Future<StockLoss> declareLoss({
    required String id,
    required String productId,
    required String locationId,
    required String quantity,
    String? comment,
  }) async {
    declared = {
      'productId': productId,
      'locationId': locationId,
      'quantity': quantity,
      'comment': comment,
    };
    return _loss();
  }

  @override
  Future<StockLoss> validateLoss(String id) async {
    calls.add('validate:$id');
    return _loss(status: StockLossStatus.validated);
  }

  @override
  Future<StockLoss> rejectLoss(String id, {String? note}) async {
    calls.add('reject:$id');
    return _loss(status: StockLossStatus.rejected);
  }
}

AuthUser _vendeur() => authUser(
  id: 'v',
  roles: const ['VENDEUR'],
  permissions: const [
    'product.read',
    'stock.read.store',
    'stock.read.warehouse',
  ],
);
AuthUser _magasinier() => authUser(
  id: 'm',
  roles: const ['MAGASINIER'],
  permissions: const ['product.read', 'stock.read.store', 'stock.loss'],
);
AuthUser _admin() => authUser(
  roles: const ['ADMIN'],
  permissions: const [
    'product.read',
    'stock.read.store',
    'stock.loss',
    'stock.adjust.validate',
  ],
);

void main() {
  late _RecordingStockApi api;

  setUp(() => api = _RecordingStockApi());

  Widget wrap(AuthUser user) {
    final products = [
      product(id: 'p1', name: 'Câble 3G2,5', minThreshold: '100'),
      product(id: 'p2', name: 'Disjoncteur 16A'),
    ];
    return ProviderScope(
      overrides: [
        stockApiProvider.overrideWithValue(api),
        productsProvider.overrideWith((ref) => Stream.value(products)),
        activeProductsProvider.overrideWith((ref) => Stream.value(products)),
        locationsProvider.overrideWith(
          (ref) => Stream.value([
            _location('magasin', 'MAGASIN', 'Magasin'),
            _location('depot', 'DEPOT', 'Dépôt'),
          ]),
        ),
        stockByProductProvider.overrideWith(
          (ref) async => {
            'p1': ProductStock([
              _level('p1', 'magasin', '20'),
              _level('p1', 'depot', '50'),
            ]),
          },
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: StockScreen(user: user)),
      ),
    );
  }

  test('ProductStock : total et disponible additionnent les emplacements', () {
    final stock = ProductStock([
      _level('p1', 'magasin', '20.5'),
      _level('p1', 'depot', '50'),
    ]);
    expect(stock.total, Decimal.parse('70.5'));
    expect(stock.at('depot'), Decimal.parse('50'));
    expect(stock.at('ailleurs'), Decimal.zero);
  });

  testWidgets('VENDEUR : niveaux par emplacement, aucune section Pertes', (
    tester,
  ) async {
    useScreenSize(tester, const Size(400, 900));
    await tester.pumpWidget(wrap(_vendeur()));
    await tester.pumpAndSettle();

    expect(find.text('Câble 3G2,5'), findsOneWidget);
    expect(find.text('20 pce'), findsOneWidget);
    expect(find.text('50 pce'), findsOneWidget);
    expect(find.text('70 pce'), findsNWidgets(2)); // total + disponible
    // 70 < seuil 100 : signalé par un LIBELLÉ, pas seulement une couleur.
    expect(find.text('Sous le seuil'), findsOneWidget);
    expect(find.text('Pertes'), findsNothing);
  });

  testWidgets(
    'MAGASINIER : déclare une perte (quantité décimale en chaîne), sans pouvoir valider',
    (tester) async {
      useScreenSize(tester, const Size(400, 1400));
      await tester.pumpWidget(wrap(_magasinier()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pertes'));
      await tester.pumpAndSettle();
      expect(find.text('Carton écrasé'), findsOneWidget);
      expect(find.text('Valider'), findsNothing);

      await tester.tap(find.text('Déclarer une perte'));
      await tester.pumpAndSettle();
      expect(find.textContaining('L’administrateur valide'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'câble');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Câble 3G2,5 — DIS-16A').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dépôt').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), '2,5');
      await tester.enterText(find.byType(TextFormField).at(1), 'Carton écrasé');
      await tester.tap(find.text('Envoyer pour validation'));
      await tester.pumpAndSettle();

      expect(api.declared, {
        'productId': 'p1',
        'locationId': 'depot',
        'quantity': '2.500',
        'comment': 'Carton écrasé',
      });
    },
  );

  testWidgets('ADMIN : valide, et refuse après confirmation', (tester) async {
    useScreenSize(tester, const Size(400, 900));
    await tester.pumpWidget(wrap(_admin()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pertes'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Valider'));
    await tester.pumpAndSettle();
    expect(api.calls, ['validate:l1']);

    await tester.tap(find.text('Refuser'));
    await tester.pumpAndSettle();
    expect(find.text('Refuser la déclaration ?'), findsOneWidget);
    await tester.tap(find.text('Refuser').last);
    await tester.pumpAndSettle();
    expect(api.calls, ['validate:l1', 'reject:l1']);
  });

  test('menu : « Stock » proposé à qui a stock.read.store', () {
    expect(destinationsFor(_vendeur()).map((d) => d.label), contains('Stock'));
    expect(
      destinationsFor(authUser(permissions: const [])).map((d) => d.label),
      isNot(contains('Stock')),
    );
  });
}
