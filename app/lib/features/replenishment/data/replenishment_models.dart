import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../data/models/page_meta.dart';

part 'replenishment_models.freezed.dart';
part 'replenishment_models.g.dart';

/// Une ligne de la liste « à racheter » (spec §19).
///
/// Les quantités arrivent en CHAÎNES décimales (`"8.000"`) et les montants en
/// centimes entiers : jamais de `double` pour une quantité ni pour de l'argent
/// (CLAUDE.md règles 4 et 10).
@freezed
abstract class ReplenishmentLine with _$ReplenishmentLine {
  const factory ReplenishmentLine({
    required String productId,
    required String sku,
    required String name,
    required String unit,
    required String quantity,
    required String minThreshold,
    required String suggestedQuantity,
    @Default(false) bool isOutOfStock,
    String? supplierId,
    String? supplierName,
    int? lastPurchasePriceHt,
  }) = _ReplenishmentLine;

  factory ReplenishmentLine.fromJson(Map<String, dynamic> json) =>
      _$ReplenishmentLineFromJson(json);
}

@freezed
abstract class ReplenishmentPage with _$ReplenishmentPage {
  const factory ReplenishmentPage({
    required List<ReplenishmentLine> data,
    required PageMeta meta,
    @Default(0) int outOfStockCount,
  }) = _ReplenishmentPage;

  factory ReplenishmentPage.fromJson(Map<String, dynamic> json) =>
      _$ReplenishmentPageFromJson(json);
}
