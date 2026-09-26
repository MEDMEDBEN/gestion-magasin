import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../data/models/page_meta.dart';

part 'quote_models.freezed.dart';
part 'quote_models.g.dart';

/// `BROUILLON → ENVOYE → ACCEPTE → CONVERTI` (+ `REFUSE`, `EXPIRE`). `EXPIRE` est
/// LU par le serveur (date de validité passée), jamais écrit.
enum QuoteStatus {
  @JsonValue('BROUILLON')
  draft('Brouillon'),
  @JsonValue('ENVOYE')
  sent('Envoyé'),
  @JsonValue('ACCEPTE')
  accepted('Accepté'),
  @JsonValue('CONVERTI')
  converted('Converti en vente'),
  @JsonValue('REFUSE')
  refused('Refusé'),
  @JsonValue('EXPIRE')
  expired('Expiré'),

  /// Statut inconnu de CETTE version : le devis reste lisible, sans action.
  unknown('—');

  const QuoteStatus(this.label);
  final String label;

  /// Mêmes transitions que le serveur (`QuotesService`).
  bool get canSend => this == QuoteStatus.draft;
  bool get canAccept => this == QuoteStatus.draft || this == QuoteStatus.sent;

  /// Un devis expiré se clôt encore en « refusé » (le serveur l'accepte) : il
  /// ne s'envoie ni ne s'accepte plus.
  bool get canRefuse =>
      canAccept || this == QuoteStatus.accepted || this == QuoteStatus.expired;
  bool get canConvert => this == QuoteStatus.accepted;
}

@freezed
abstract class QuoteLine with _$QuoteLine {
  const factory QuoteLine({
    required String id,
    required String productId,
    required String quantity,
    required int unitPriceHt,
    required String taxRate,
    @Default(0) int discountAmount,
    required int lineTotalHt,
    required int lineTaxAmount,
    required int lineTotalTtc,
  }) = _QuoteLine;

  factory QuoteLine.fromJson(Map<String, dynamic> json) =>
      _$QuoteLineFromJson(json);
}

/// Montants en centimes (règle 4). Un devis ne touche jamais le stock.
@freezed
abstract class Quote with _$Quote {
  const factory Quote({
    required String id,
    required String number,
    @JsonKey(unknownEnumValue: QuoteStatus.unknown) required QuoteStatus status,
    String? customerId,
    String? customerName,
    required String userId,
    String? validUntil,
    required int totalHt,
    required int totalTax,
    required int totalTtc,
    String? note,
    String? saleId,
    required DateTime createdAt,
    @Default(<QuoteLine>[]) List<QuoteLine> lines,
  }) = _Quote;

  factory Quote.fromJson(Map<String, dynamic> json) => _$QuoteFromJson(json);
}

@freezed
abstract class QuotePage with _$QuotePage {
  const factory QuotePage({required List<Quote> data, required PageMeta meta}) =
      _QuotePage;

  factory QuotePage.fromJson(Map<String, dynamic> json) =>
      _$QuotePageFromJson(json);
}
