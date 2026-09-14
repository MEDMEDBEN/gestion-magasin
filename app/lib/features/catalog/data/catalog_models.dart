import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/quantity.dart';

part 'catalog_models.freezed.dart';
part 'catalog_models.g.dart';

/// Unités de vente — alignées sur l'enum `ProductUnit` (Prisma).
enum ProductUnit {
  @JsonValue('PIECE')
  piece,
  @JsonValue('METRE')
  metre,
  @JsonValue('ROULEAU')
  rouleau,
  @JsonValue('BOITE')
  boite,
  @JsonValue('PAQUET')
  paquet,
  @JsonValue('KILOGRAMME')
  kilogramme,
}

extension ProductUnitLabel on ProductUnit {
  String get code => switch (this) {
    ProductUnit.piece => 'PIECE',
    ProductUnit.metre => 'METRE',
    ProductUnit.rouleau => 'ROULEAU',
    ProductUnit.boite => 'BOITE',
    ProductUnit.paquet => 'PAQUET',
    ProductUnit.kilogramme => 'KILOGRAMME',
  };

  String get label => switch (this) {
    ProductUnit.piece => 'Pièce',
    ProductUnit.metre => 'Mètre',
    ProductUnit.rouleau => 'Rouleau',
    ProductUnit.boite => 'Boîte',
    ProductUnit.paquet => 'Paquet',
    ProductUnit.kilogramme => 'Kilogramme',
  };

  /// Abrégé des tableaux (« m », « pce »).
  String get short => switch (this) {
    ProductUnit.piece => 'pce',
    ProductUnit.metre => 'm',
    ProductUnit.rouleau => 'rlx',
    ProductUnit.boite => 'bte',
    ProductUnit.paquet => 'pqt',
    ProductUnit.kilogramme => 'kg',
  };
}

/// Miroir de `ProductDto`. Quantités en `Decimal` (règle 10), montants en
/// centimes `int` (règle 4).
@freezed
abstract class Product with _$Product {
  const factory Product({
    required String id,
    required String sku,
    required String barcode,
    required String name,
    String? description,
    String? brand,
    required ProductUnit unit,
    String? categoryId,
    String? taxRateId,
    String? mainSupplierId,
    String? storageLocationId,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity minThreshold,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity safetyStock,
    int? lastPurchasePriceHt,
    required bool allowBackorder,
    required bool isActive,
    required DateTime updatedAt,
  }) = _Product;

  factory Product.fromJson(Map<String, dynamic> json) =>
      _$ProductFromJson(json);
}

/// Miroir de `CategoryDto` — deux niveaux : catégorie → sous-catégorie.
@freezed
abstract class ProductCategory with _$ProductCategory {
  const factory ProductCategory({
    required String id,
    required String name,
    String? parentId,
    String? description,
    required bool isActive,
    required DateTime updatedAt,
  }) = _ProductCategory;

  factory ProductCategory.fromJson(Map<String, dynamic> json) =>
      _$ProductCategoryFromJson(json);
}

/// Miroir de `LocationDto`. MAGASIN / DEPOT / TRANSIT portent le stock ;
/// EMPLACEMENT = position physique au dépôt (Zone → Rayon → Étagère → Position).
@freezed
abstract class StorageLocation with _$StorageLocation {
  const StorageLocation._();

  const factory StorageLocation({
    required String id,
    required String code,
    required String name,
    required String type,
    String? parentId,
    String? zone,
    String? aisle,
    String? shelf,
    String? position,
    required bool isActive,
    required DateTime updatedAt,
  }) = _StorageLocation;

  factory StorageLocation.fromJson(Map<String, dynamic> json) =>
      _$StorageLocationFromJson(json);

  bool get isBin => type == 'EMPLACEMENT';
}

/// Miroir de `TaxRateDto`. Le taux reste une chaîne décimale (« 19.00 »).
@freezed
abstract class TaxRate with _$TaxRate {
  const factory TaxRate({
    required String id,
    required String code,
    required String name,
    required String rate,
    required bool isDefault,
    required bool isActive,
    required DateTime updatedAt,
  }) = _TaxRate;

  factory TaxRate.fromJson(Map<String, dynamic> json) =>
      _$TaxRateFromJson(json);
}

/// Page de la descente delta (`GET /catalog/changes`).
@freezed
abstract class CatalogChanges with _$CatalogChanges {
  const factory CatalogChanges({
    required List<Product> products,
    required List<ProductCategory> categories,
    required List<StorageLocation> locations,
    required List<TaxRate> taxRates,
    required String cursor,
    required bool hasMore,
  }) = _CatalogChanges;

  factory CatalogChanges.fromJson(Map<String, dynamic> json) =>
      _$CatalogChangesFromJson(json);
}
