import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_api.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';

/// Fabriques de modèles du catalogue pour les tests.
Product product({
  String id = 'p1',
  String name = 'Disjoncteur 16A',
  String sku = 'DIS-16A',
  String barcode = '2000000000015',
  String? brand,
  String? categoryId,
  ProductUnit unit = ProductUnit.piece,
  String minThreshold = '0',
  bool isActive = true,
}) => Product(
  id: id,
  sku: sku,
  barcode: barcode,
  name: name,
  brand: brand,
  unit: unit,
  categoryId: categoryId,
  minThreshold: Decimal.parse(minThreshold),
  safetyStock: Decimal.zero,
  allowBackorder: false,
  isActive: isActive,
  updatedAt: DateTime.utc(2026, 9, 14),
);

ProductCategory category({
  String id = 'cat',
  String name = 'Câbles',
  String? parentId,
}) => ProductCategory(
  id: id,
  name: name,
  parentId: parentId,
  isActive: true,
  updatedAt: DateTime.utc(2026, 9, 14),
);

/// Faux client d'API : enregistre ce qui PART au serveur et renvoie un produit.
class RecordingCatalogApi extends CatalogApi {
  RecordingCatalogApi() : super(Dio());

  final List<(String? id, Map<String, Object?> fields)> productCalls = [];

  /// Étiquettes demandées : support, puis (produit, exemplaires).
  final List<(String, List<({String productId, int copies})>)> labelCalls = [];

  @override
  Future<Uint8List> labels({
    required String format,
    required List<({String productId, int copies})> items,
  }) async {
    labelCalls.add((format, items));
    return Uint8List(4);
  }

  @override
  Future<Product> createProduct(Map<String, Object?> fields) async {
    productCalls.add((null, fields));
    return product(
      id: 'new',
      name: fields['name']! as String,
      sku: fields['sku']! as String,
    );
  }

  @override
  Future<Product> updateProduct(String id, Map<String, Object?> changes) async {
    productCalls.add((id, changes));
    return product(id: id, name: (changes['name'] as String?) ?? 'Modifié');
  }

  @override
  Future<List<Map<String, dynamic>>> priceHistory(String productId) async => [
    {
      'at': '2026-09-20T10:00:00.000Z',
      'tier': 'DETAIL',
      'oldPriceHt': 145000,
      'newPriceHt': 150000,
      'by': null,
    },
    {
      'at': '2026-09-01T10:00:00.000Z',
      'tier': 'DETAIL',
      'oldPriceHt': null,
      'newPriceHt': 145000,
      'by': null,
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> prospects(String productId) async => [
    {
      'customerId': 'c1',
      'name': 'Électricité Benali',
      'phone': '0550 00 00 01',
      'email': null,
      'purchases': 3,
      'lastPurchaseAt': '2026-09-20T10:00:00.000Z',
      'message': 'Bonjour Électricité Benali, nouveau produit : Câble 3G2.5.',
    },
  ];

  @override
  Future<CatalogChanges> changes({String? cursor, int limit = 500}) async =>
      const CatalogChanges(
        products: [],
        categories: [],
        locations: [],
        taxRates: [],
        cursor: 'c',
        hasMore: false,
      );
}
