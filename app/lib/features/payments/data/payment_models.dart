import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../data/models/page_meta.dart';

part 'payment_models.freezed.dart';
part 'payment_models.g.dart';

/// Ligne d'historique d'un règlement client ou d'un paiement fournisseur —
/// même contrat serveur (`common/dto/payment.dto.ts`). Montant en centimes,
/// NÉGATIF pour une contre-passation.
@freezed
abstract class PaymentHistoryItem with _$PaymentHistoryItem {
  const factory PaymentHistoryItem({
    required String id,
    required int amount,
    required String method,
    required bool fromCash,
    required DateTime paidAt,
    required String userId,
    String? saleId,
    String? note,
    String? reversesPaymentId,
    String? reversedById,
  }) = _PaymentHistoryItem;

  const PaymentHistoryItem._();

  /// Un paiement ordinaire, pas encore annulé : seul cas contre-passable.
  bool get canBeReversed => reversesPaymentId == null && reversedById == null;

  factory PaymentHistoryItem.fromJson(Map<String, dynamic> json) =>
      _$PaymentHistoryItemFromJson(json);
}

@freezed
abstract class PaymentHistoryPage with _$PaymentHistoryPage {
  const factory PaymentHistoryPage({
    required List<PaymentHistoryItem> data,
    required PageMeta meta,
  }) = _PaymentHistoryPage;

  factory PaymentHistoryPage.fromJson(Map<String, dynamic> json) =>
      _$PaymentHistoryPageFromJson(json);
}
