import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/quantity.dart';
import '../../../data/models/page_meta.dart';

part 'receptions_models.freezed.dart';
part 'receptions_models.g.dart';

/// Montants : centimes `int` (règle 4). Quantités : `Decimal` (règle 10).

@freezed
abstract class ReceptionLine with _$ReceptionLine {
  const factory ReceptionLine({
    required String id,
    required String productId,
    String? purchaseLineId,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity receivedQuantity,
    required int unitPriceHt,
    required int lineTotalHt,
    required int lineTotalTtc,
  }) = _ReceptionLine;

  factory ReceptionLine.fromJson(Map<String, dynamic> json) =>
      _$ReceptionLineFromJson(json);
}

@freezed
abstract class Reception with _$Reception {
  const factory Reception({
    required String id,
    required String number,
    String? purchaseOrderId,
    required String supplierId,
    required String locationId,
    required DateTime receivedAt,
    String? note,

    /// Montant TTC ajouté à la dette fournisseur par cette réception.
    required int totalTtc,
    required List<ReceptionLine> lines,
  }) = _Reception;

  factory Reception.fromJson(Map<String, dynamic> json) =>
      _$ReceptionFromJson(json);
}

@freezed
abstract class ReceptionPage with _$ReceptionPage {
  const factory ReceptionPage({
    required List<Reception> data,
    required PageMeta meta,
  }) = _ReceptionPage;

  factory ReceptionPage.fromJson(Map<String, dynamic> json) =>
      _$ReceptionPageFromJson(json);
}
