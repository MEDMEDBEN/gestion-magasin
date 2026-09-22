import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/money.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/scan/presentation/scan_screen.dart';
import 'package:gestion_magasin/features/scan/presentation/scanned_product_sheet.dart';
import 'package:gestion_magasin/features/sales/application/sales_controller.dart';
import 'package:gestion_magasin/features/stock/application/stock_controller.dart';
import 'package:gestion_magasin/features/stock/data/stock_models.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';
import 'support/fakes.dart';

Product _cable() =>
    product(id: 'p1', name: 'Câble 3G2,5', sku: 'CAB-3G25').copyWith(
      barcode: '3245060123458',
      prices: const [ProductPriceLine(priceTierId: 'detail', priceHt: 145000)],
    );

StorageLocation _location(String id, String name) => StorageLocation(
  id: id,
  code: id.toUpperCase(),
  name: name,
  type: id == 'depot' ? 'DEPOT' : 'MAGASIN',
  isActive: true,
  updatedAt: DateTime.utc(2026),
);

StockLevel _level(String locationId, String quantity) => StockLevel(
  productId: 'p1',
  locationId: locationId,
  quantity: Decimal.parse(quantity),
  reservedQuantity: Decimal.zero,
  inTransitQuantity: Decimal.zero,
  availableQuantity: Decimal.parse(quantity),
);

Future<void> _pump(
  WidgetTester tester, {
  required String barcode,
  ProductStock? stocks,
  Object? stockError,
  List<String> permissions = const [
    'sale.create',
    'product.read',
    'price.read',
    'stock.read.store',
  ],
}) async {
  useScreenSize(tester, const Size(400, 800));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserIdProvider.overrideWithValue('v'),
        activeProductsProvider.overrideWith((ref) => Stream.value([_cable()])),
        locationsProvider.overrideWith(
          (ref) => Stream.value([
            _location('magasin', 'Magasin'),
            _location('depot', 'Dépôt'),
          ]),
        ),
        priceTiersProvider.overrideWith(
          (ref) async => const [
            PriceTier(
              id: 'detail',
              code: 'DETAIL',
              name: 'Détail',
              isDefault: true,
            ),
          ],
        ),
        productStockProvider('p1').overrideWith((ref) async {
          if (stockError != null) throw stockError;
          return stocks ?? const ProductStock([]);
        }),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(
          body: ScannedProductSheet(
            barcode: barcode,
            user: authUser(roles: const ['VENDEUR'], permissions: permissions),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('le code-barres désigne UN produit du catalogue local', () {
    final products = [_cable()];
    expect(productForBarcode(products, '3245060123458')?.id, 'p1');
    // Espaces d'une douchette ou d'une saisie : ignorés.
    expect(productForBarcode(products, ' 3245060123458 ')?.id, 'p1');
    expect(productForBarcode(products, '0000000000000'), isNull);
    expect(productForBarcode(products, ''), isNull);
  });

  testWidgets('code connu : produit, prix et stock par emplacement (§27)', (
    tester,
  ) async {
    await _pump(
      tester,
      barcode: '3245060123458',
      stocks: ProductStock([_level('magasin', '4'), _level('depot', '12')]),
    );

    expect(find.text('Câble 3G2,5'), findsOneWidget);
    expect(find.text('${formatDA(145000)} HT'), findsOneWidget);
    expect(find.textContaining('Magasin : 4'), findsOneWidget);
    expect(find.textContaining('Dépôt : 12'), findsOneWidget);
    expect(find.text('Ajouter au panier'), findsOneWidget);
  });

  testWidgets('code inconnu : dit lequel, ne propose aucune action', (
    tester,
  ) async {
    await _pump(tester, barcode: '0000000000000');

    expect(find.text('Code inconnu'), findsOneWidget);
    expect(find.textContaining('0000000000000'), findsOneWidget);
    expect(find.text('Ajouter au panier'), findsNothing);
  });

  testWidgets(
    'hors ligne : le produit s’affiche, le stock est annoncé indisponible',
    (tester) async {
      await _pump(
        tester,
        barcode: '3245060123458',
        stockError: const ApiException(statusCode: 0, message: 'hors ligne'),
      );

      // Le catalogue est local : le scan répond sans réseau…
      expect(find.text('Câble 3G2,5'), findsOneWidget);
      // …mais le stock vient du serveur : jamais inventé.
      expect(
        find.textContaining('Stock indisponible hors ligne'),
        findsOneWidget,
      );
    },
  );

  testWidgets('« Ajouter au panier » met bien le produit dans le panier', (
    tester,
  ) async {
    await _pump(
      tester,
      barcode: '3245060123458',
      stocks: const ProductStock([]),
    );
    final context = tester.element(find.text('Ajouter au panier'));
    final container = ProviderScope.containerOf(context);

    await tester.tap(find.text('Ajouter au panier'));
    await tester.pumpAndSettle();

    expect(container.read(cartProvider).lines.single.product.id, 'p1');
  });

  testWidgets(
    'refus de DROIT sur le stock : dit le motif, pas « hors ligne »',
    (tester) async {
      await _pump(
        tester,
        barcode: '3245060123458',
        stockError: const ApiException(
          statusCode: 403,
          message: 'Permission manquante',
          code: 'FORBIDDEN_PERMISSION',
        ),
      );

      expect(find.textContaining('Stock non accessible'), findsOneWidget);
      expect(find.textContaining('hors ligne'), findsNothing);
    },
  );

  testWidgets('sans les droits de lecture : ni prix ni stock affichés', (
    tester,
  ) async {
    await _pump(
      tester,
      barcode: '3245060123458',
      stocks: ProductStock([_level('magasin', '4')]),
      permissions: const ['product.read'],
    );

    expect(find.text('Câble 3G2,5'), findsOneWidget);
    expect(find.textContaining('DA HT'), findsNothing);
    expect(find.textContaining('Magasin :'), findsNothing);
  });

  test(
    'un code démesuré (QR bavard) ne devient pas un produit ni un message brut',
    () {
      final long = 'A' * 500;
      expect(productForBarcode([_cable()], long), isNull);
      expect(readableBarcode(long).length, lessThanOrEqualTo(65));
      // Caractères de mise en forme (bidi) retirés avant affichage.
      final bidi = String.fromCharCode(0x202E); // renverse l'affichage
      expect(readableBarcode('123${bidi}456'), '123456');
    },
  );

  test('un seul code à la fois : le premier code non vide de la capture', () {
    expect(firstBarcode([null, '', '  ', ' 3245060123458 ']), '3245060123458');
    expect(firstBarcode([null, '']), isNull);
    expect(firstBarcode(const []), isNull);
  });

  test(
    'le scanner est une entrée MOBILE : jamais dans la sidebar du poste',
    () {
      final entries = destinationsFor(
        authUser(
          roles: const ['MAGASINIER'],
          permissions: const ['product.read'],
        ),
      );
      final scan = entries.where((d) => d.label == 'Scanner');
      expect(scan, hasLength(1), reason: 'proposé à qui lit le catalogue');
      expect(scan.single.mobileOnly, isTrue);
    },
  );
}
