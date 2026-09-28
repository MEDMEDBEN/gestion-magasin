import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../data/models/page_meta.dart';

part 'suppliers_models.freezed.dart';
part 'suppliers_models.g.dart';

/// Montants en centimes `int` (règle 4). La dette n'est jamais stockée : le
/// serveur la recalcule (reprise de l'existant − paiements).
@freezed
abstract class Supplier with _$Supplier {
  const factory Supplier({
    required String id,
    String? code,
    required String name,
    String? phone,
    String? email,
    String? address,
    String? contactName,
    String? notes,
    required int openingBalance,
    required int paidAmount,
    required int balanceDue,

    /// Total TTC réellement reçu, net des retours : le « total acheté ».
    @Default(0) int receivedAmount,
    required bool isActive,
  }) = _Supplier;

  factory Supplier.fromJson(Map<String, dynamic> json) =>
      _$SupplierFromJson(json);
}

@freezed
abstract class SupplierPage with _$SupplierPage {
  const factory SupplierPage({
    required List<Supplier> data,
    required PageMeta meta,
  }) = _SupplierPage;

  factory SupplierPage.fromJson(Map<String, dynamic> json) =>
      _$SupplierPageFromJson(json);
}

/// Prix d'achat d'un produit chez ce fournisseur, d'une réception à l'autre.
@freezed
abstract class SupplierProductPrice with _$SupplierProductPrice {
  const factory SupplierProductPrice({
    required String productId,
    required String name,
    required String sku,
    required int receptions,
    required int firstPriceHt,
    int? previousPriceHt,
    required int lastPriceHt,
    required DateTime lastReceivedAt,
  }) = _SupplierProductPrice;

  factory SupplierProductPrice.fromJson(Map<String, dynamic> json) =>
      _$SupplierProductPriceFromJson(json);
}

/// Indicateurs d'un fournisseur (P1 bis n°21m), lus des réceptions.
@freezed
abstract class SupplierStats with _$SupplierStats {
  const factory SupplierStats({
    required int productCount,
    required int deliveriesWithDate,
    required int deliveriesOnTime,
    @Default(<SupplierProductPrice>[]) List<SupplierProductPrice> prices,
  }) = _SupplierStats;

  factory SupplierStats.fromJson(Map<String, dynamic> json) =>
      _$SupplierStatsFromJson(json);
}

@freezed
abstract class SupplierPayment with _$SupplierPayment {
  const factory SupplierPayment({
    required String id,
    required String supplierId,
    required int amount,
    required String method,
    required bool fromCash,
    required DateTime paidAt,
    required int balanceDue,
  }) = _SupplierPayment;

  factory SupplierPayment.fromJson(Map<String, dynamic> json) =>
      _$SupplierPaymentFromJson(json);
}
