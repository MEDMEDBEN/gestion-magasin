import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/quantity.dart';
import '../../../data/models/page_meta.dart';

part 'stock_models.freezed.dart';
part 'stock_models.g.dart';

/// Miroir de `StockDto` : stock d'un produit à un emplacement. Quantités en
/// `Decimal` (règle 10). `available` = quantité − réservé : c'est lui qui
/// autorise une vente.
@freezed
abstract class StockLevel with _$StockLevel {
  const factory StockLevel({
    required String productId,
    required String locationId,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity quantity,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity reservedQuantity,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity inTransitQuantity,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity availableQuantity,
  }) = _StockLevel;

  factory StockLevel.fromJson(Map<String, dynamic> json) =>
      _$StockLevelFromJson(json);
}

@freezed
abstract class StockLevelPage with _$StockLevelPage {
  const factory StockLevelPage({
    required List<StockLevel> data,
    required PageMeta meta,
  }) = _StockLevelPage;

  factory StockLevelPage.fromJson(Map<String, dynamic> json) =>
      _$StockLevelPageFromJson(json);
}

/// Miroir de `StockMovementDto` — une ligne du journal IMMUABLE.
@freezed
abstract class StockMovementEntry with _$StockMovementEntry {
  const factory StockMovementEntry({
    required String id,
    required String productId,
    required String locationId,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity quantity,
    required String type,
    String? userId,
    String? comment,
    required DateTime createdAt,
  }) = _StockMovementEntry;

  factory StockMovementEntry.fromJson(Map<String, dynamic> json) =>
      _$StockMovementEntryFromJson(json);
}

@freezed
abstract class StockMovementPage with _$StockMovementPage {
  const factory StockMovementPage({
    required List<StockMovementEntry> data,
    required PageMeta meta,
  }) = _StockMovementPage;

  factory StockMovementPage.fromJson(Map<String, dynamic> json) =>
      _$StockMovementPageFromJson(json);
}

enum StockLossStatus {
  @JsonValue('EN_ATTENTE')
  pending,
  @JsonValue('VALIDEE')
  validated,
  @JsonValue('REFUSEE')
  rejected,
}

extension StockLossStatusCode on StockLossStatus {
  String get code => switch (this) {
    StockLossStatus.pending => 'EN_ATTENTE',
    StockLossStatus.validated => 'VALIDEE',
    StockLossStatus.rejected => 'REFUSEE',
  };

  String get label => switch (this) {
    StockLossStatus.pending => 'En attente',
    StockLossStatus.validated => 'Validée',
    StockLossStatus.rejected => 'Refusée',
  };
}

/// Miroir de `StockLossDto`. Celle du magasinier attend la validation de
/// l'admin avant de toucher le stock.
@freezed
abstract class StockLoss with _$StockLoss {
  const factory StockLoss({
    required String id,
    required String productId,
    required String locationId,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity quantity,
    String? comment,
    required StockLossStatus status,
    required String declaredById,
    String? decidedById,
    DateTime? decidedAt,
    String? decisionNote,
    String? movementId,
    required DateTime createdAt,
  }) = _StockLoss;

  factory StockLoss.fromJson(Map<String, dynamic> json) =>
      _$StockLossFromJson(json);
}

@freezed
abstract class StockLossPage with _$StockLossPage {
  const factory StockLossPage({
    required List<StockLoss> data,
    required PageMeta meta,
  }) = _StockLossPage;

  factory StockLossPage.fromJson(Map<String, dynamic> json) =>
      _$StockLossPageFromJson(json);
}
