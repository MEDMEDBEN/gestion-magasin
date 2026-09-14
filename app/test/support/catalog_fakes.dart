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
