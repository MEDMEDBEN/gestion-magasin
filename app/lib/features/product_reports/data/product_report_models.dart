import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../data/models/page_meta.dart';

part 'product_report_models.freezed.dart';
part 'product_report_models.g.dart';

/// Un produit dormant (spec §20) : il a du stock et ne se vend plus.
///
/// Quantités en CHAÎNES décimales, montants en centimes entiers (règles 4 et 10).
@freezed
abstract class DormantProduct with _$DormantProduct {
  const factory DormantProduct({
    required String productId,
    required String sku,
    required String name,
    required String unit,
    required String quantity,
    DateTime? lastSoldAt,
    DateTime? lastMovementAt,
    int? sleepingValueHt,
  }) = _DormantProduct;

  factory DormantProduct.fromJson(Map<String, dynamic> json) =>
      _$DormantProductFromJson(json);
}

@freezed
abstract class DormantProductPage with _$DormantProductPage {
  const factory DormantProductPage({
    required List<DormantProduct> data,
    required PageMeta meta,
    @Default(120) int days,
    int? totalSleepingValueHt,
  }) = _DormantProductPage;

  factory DormantProductPage.fromJson(Map<String, dynamic> json) =>
      _$DormantProductPageFromJson(json);
}

/// Une ligne de classement. `quantity` est la grandeur mesurée par SA liste
/// (vendu, demandé, ou non servi) ; `revenueHt` n'existe que pour les ventes.
@freezed
abstract class DemandLine with _$DemandLine {
  const factory DemandLine({
    required String productId,
    required String sku,
    required String name,
    required String unit,
    required String quantity,
    int? revenueHt,
  }) = _DemandLine;

  factory DemandLine.fromJson(Map<String, dynamic> json) =>
      _$DemandLineFromJson(json);
}

@freezed
abstract class ProductDemand with _$ProductDemand {
  const factory ProductDemand({
    @Default(30) int days,
    @Default([]) List<DemandLine> bestSellers,
    @Default([]) List<DemandLine> mostRequested,
    @Default([]) List<DemandLine> unmetDemand,
  }) = _ProductDemand;

  factory ProductDemand.fromJson(Map<String, dynamic> json) =>
      _$ProductDemandFromJson(json);
}
