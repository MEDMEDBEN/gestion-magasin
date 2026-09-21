import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/quantity.dart';
import '../../../data/models/page_meta.dart';

part 'inventory_models.freezed.dart';
part 'inventory_models.g.dart';

/// Quantités : `Decimal` (règle 10). Un inventaire ne porte aucun montant.

/// Machine à états figée (`docs/plan.md`) : EN_COURS → TERMINE.
enum InventoryStatus {
  @JsonValue('EN_COURS')
  inProgress('En cours'),
  @JsonValue('TERMINE')
  completed('Comptage terminé');

  const InventoryStatus(this.label);
  final String label;
}

enum InventoryType {
  @JsonValue('COMPLET')
  full('Complet'),
  @JsonValue('TOURNANT')
  cycle('Tournant');

  const InventoryType(this.label);
  final String label;
}

enum InventoryLineState {
  @JsonValue('CONFORME')
  matching('Conforme'),
  @JsonValue('ECART')
  gap('Écart');

  const InventoryLineState(this.label);
  final String label;
}

@freezed
abstract class InventoryLine with _$InventoryLine {
  const factory InventoryLine({
    required String id,
    required String productId,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity theoreticalQuantity,
    @JsonKey(fromJson: _nullableQuantity, toJson: _nullableQuantityToJson)
    Quantity? countedQuantity,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity difference,
    required InventoryLineState state,
    String? note,
  }) = _InventoryLine;

  factory InventoryLine.fromJson(Map<String, dynamic> json) =>
      _$InventoryLineFromJson(json);
}

/// `null` = produit pas encore compté, à distinguer d'un comptage à zéro.
Quantity? _nullableQuantity(Object? value) =>
    value == null ? null : quantityFromJson(value);
String? _nullableQuantityToJson(Quantity? value) =>
    value == null ? null : quantityToJson(value);

@freezed
abstract class Inventory with _$Inventory {
  const factory Inventory({
    required String id,
    required String number,
    required InventoryStatus status,
    required InventoryType type,
    required String locationId,
    String? zone,
    required String createdById,
    String? validatedById,
    required DateTime startedAt,
    DateTime? completedAt,
    DateTime? validatedAt,
    String? note,
    required DateTime updatedAt,
    required List<InventoryLine> lines,
  }) = _Inventory;
  const Inventory._();

  factory Inventory.fromJson(Map<String, dynamic> json) =>
      _$InventoryFromJson(json);

  /// Comptage clos et pas encore validé : c'est ce que l'admin doit traiter.
  bool get awaitsValidation =>
      status == InventoryStatus.completed && validatedAt == null;

  Iterable<InventoryLine> get gaps =>
      lines.where((l) => l.state == InventoryLineState.gap);

  int get countedCount => lines.where((l) => l.countedQuantity != null).length;
}

@freezed
abstract class InventoryPage with _$InventoryPage {
  const factory InventoryPage({
    required List<Inventory> data,
    required PageMeta meta,
  }) = _InventoryPage;

  factory InventoryPage.fromJson(Map<String, dynamic> json) =>
      _$InventoryPageFromJson(json);
}
