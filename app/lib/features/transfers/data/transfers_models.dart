import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/quantity.dart';
import '../../../data/models/page_meta.dart';

part 'transfers_models.freezed.dart';
part 'transfers_models.g.dart';

/// Quantités : `Decimal` (règle 10). Un transfert ne porte aucun montant.

/// Machine à états figée (`docs/plan.md`) : DEMANDEE → ACCEPTEE →
/// EN_PREPARATION → PREPAREE → EN_TRANSIT → RECUE (+ REFUSEE, ANNULEE).
enum TransferStatus {
  @JsonValue('DEMANDEE')
  requested('Demandée'),
  @JsonValue('ACCEPTEE')
  accepted('Acceptée'),
  @JsonValue('EN_PREPARATION')
  preparing('En préparation'),
  @JsonValue('PREPAREE')
  prepared('Préparée'),
  @JsonValue('EN_TRANSIT')
  inTransit('En transit'),
  @JsonValue('RECUE')
  received('Reçue'),
  @JsonValue('REFUSEE')
  refused('Refusée'),
  @JsonValue('ANNULEE')
  cancelled('Annulée');

  const TransferStatus(this.label);
  final String label;

  /// Le dépôt peut encore travailler la demande — et rien n'a bougé en stock,
  /// donc elle s'abandonne encore (miroir du serveur).
  bool get isPreparable =>
      this == requested ||
      this == accepted ||
      this == preparing ||
      this == prepared;
}

enum TransferPriority {
  @JsonValue('BASSE')
  low('Basse'),
  @JsonValue('NORMALE')
  normal('Normale'),
  @JsonValue('HAUTE')
  high('Haute'),
  @JsonValue('URGENTE')
  urgent('Urgente');

  const TransferPriority(this.label);
  final String label;
}

@freezed
abstract class TransferLine with _$TransferLine {
  const factory TransferLine({
    required String id,
    required String productId,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity requestedQuantity,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity preparedQuantity,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity shippedQuantity,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity receivedQuantity,
  }) = _TransferLine;

  factory TransferLine.fromJson(Map<String, dynamic> json) =>
      _$TransferLineFromJson(json);
}

@freezed
abstract class Transfer with _$Transfer {
  const factory Transfer({
    required String id,
    required String number,
    required TransferStatus status,
    required TransferPriority priority,
    required String fromLocationId,
    required String toLocationId,
    required String requestedById,
    String? preparedById,
    String? receivedById,
    required DateTime requestedAt,
    DateTime? preparedAt,
    DateTime? shippedAt,
    DateTime? receivedAt,
    String? comment,
    required DateTime updatedAt,
    required List<TransferLine> lines,
  }) = _Transfer;

  factory Transfer.fromJson(Map<String, dynamic> json) =>
      _$TransferFromJson(json);
}

@freezed
abstract class TransferPage with _$TransferPage {
  const factory TransferPage({
    required List<Transfer> data,
    required PageMeta meta,
  }) = _TransferPage;

  factory TransferPage.fromJson(Map<String, dynamic> json) =>
      _$TransferPageFromJson(json);
}
