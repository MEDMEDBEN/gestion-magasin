import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/quantity.dart';
import '../../../data/models/page_meta.dart';

part 'purchases_models.freezed.dart';
part 'purchases_models.g.dart';

/// Montants : centimes `int` (règle 4). Quantités : `Decimal` (règle 10).

enum PurchaseStatus {
  @JsonValue('BROUILLON')
  draft('Brouillon'),
  @JsonValue('COMMANDEE')
  ordered('Commandée'),
  @JsonValue('CONFIRMEE')
  confirmed('Confirmée'),
  @JsonValue('PARTIELLEMENT_RECUE')
  partiallyReceived('Reçue en partie'),
  @JsonValue('RECUE')
  received('Reçue'),
  @JsonValue('ANNULEE')
  cancelled('Annulée');

  const PurchaseStatus(this.label);
  final String label;

  /// Modifiable tant que rien n'est confirmé (miroir du serveur).
  bool get isEditable => this == draft || this == ordered;
}

@freezed
abstract class PurchaseLine with _$PurchaseLine {
  const factory PurchaseLine({
    required String id,
    required String productId,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity orderedQuantity,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity receivedQuantity,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity remainingQuantity,
    required int unitPriceHt,
    required String taxRate,
    required int lineTotalHt,
    required int lineTotalTtc,
  }) = _PurchaseLine;

  factory PurchaseLine.fromJson(Map<String, dynamic> json) =>
      _$PurchaseLineFromJson(json);
}

@freezed
abstract class PurchaseOrder with _$PurchaseOrder {
  const factory PurchaseOrder({
    required String id,
    required String number,
    required String supplierId,
    required PurchaseStatus status,
    required DateTime orderDate,
    DateTime? expectedDate,
    DateTime? confirmedAt,
    required int totalHt,
    required int totalTax,
    required int totalTtc,
    String? note,
    required List<PurchaseLine> lines,
  }) = _PurchaseOrder;

  factory PurchaseOrder.fromJson(Map<String, dynamic> json) =>
      _$PurchaseOrderFromJson(json);
}

@freezed
abstract class PurchaseOrderPage with _$PurchaseOrderPage {
  const factory PurchaseOrderPage({
    required List<PurchaseOrder> data,
    required PageMeta meta,
  }) = _PurchaseOrderPage;

  factory PurchaseOrderPage.fromJson(Map<String, dynamic> json) =>
      _$PurchaseOrderPageFromJson(json);
}
