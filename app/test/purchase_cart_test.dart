import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_api.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_repository.dart';
import 'package:gestion_magasin/features/purchases/application/purchase_cart.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_api.dart';
import 'package:gestion_magasin/features/stock/application/stock_controller.dart';

import 'support/catalog_fakes.dart';

class _Purchases extends PurchasesApi {
  _Purchases() : super(Dio());
  Map<String, dynamic>? sent;

  @override
  Future<List<String>> directPurchase(Map<String, dynamic> body) async {
    sent = body;
    return ['REC-1'];
  }
}

/// Le serveur rend le produit À JOUR : nouveau coût, « prix à revoir ».
class _Catalog extends CatalogApi {
  _Catalog() : super(Dio());

  @override
  Future<Product> product(String id) async => product0(
    id,
  ).copyWith(lastPurchasePriceHt: 120000, priceReviewNeeded: true);
}

Product product0(String id) => product(id: id, name: 'Câble');

void main() {
  // 2026-11-19 : « le prix d'achat ne change pas après l'achat » — le
  // catalogue local doit relire le produit tout de suite.
  test(
    'achat validé : le produit est relu (prix d’achat, prix à revoir)',
    () async {
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      final purchases = _Purchases();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          purchasesApiProvider.overrideWithValue(purchases),
          catalogApiProvider.overrideWithValue(_Catalog()),
          currentUserIdProvider.overrideWithValue('me'),
          stockByProductProvider.overrideWith((ref) async => const {}),
        ],
      );
      addTearDown(container.dispose);
      final repo = container.read(catalogRepositoryProvider);
      await repo.saveAll(products: [product0('p1')]);

      final line = PurchaseCartLine(
        product: product0('p1'),
        unitPriceHt: 120000,
        store: Decimal.fromInt(3),
        split: Decimal.fromInt(10),
      );
      await container.read(purchaseSubmitProvider)(
        cart: PurchaseCart(id: 'c1', supplierId: 's1', lines: [line]),
        paidAmount: 100000,
      );

      expect(purchases.sent!['lines'], [
        {
          'productId': 'p1',
          'unitPriceHt': 120000,
          'toStore': '3.000',
          'toSplit': '10.000',
        },
      ]);
      expect(purchases.sent!['paidAmount'], 100000);
      final cached = (await repo.watchProducts().first).single;
      expect(cached.lastPurchasePriceHt, 120000);
      expect(cached.priceReviewNeeded, isTrue);
    },
  );
}
