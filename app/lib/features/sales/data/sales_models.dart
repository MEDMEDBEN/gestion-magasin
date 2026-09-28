import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/quantity.dart';
import '../../../data/models/page_meta.dart';

part 'sales_models.freezed.dart';
part 'sales_models.g.dart';

/// Montants : centimes `int` partout (règle 4). Quantités : `Decimal` (règle 10).

@freezed
abstract class CashSession with _$CashSession {
  const factory CashSession({
    /// Caissier (liste admin des caisses).
    String? userFullName,
    required String id,
    required String status,
    required int openingFloat,
    required int cashSalesAmount,
    required int cashSalesCount,
    required int currentAmount,
    @Default(0) int cashInAmount,
    @Default(0) int cashOutAmount,
    int? expectedAmount,
    int? countedAmount,
    int? difference,
    required DateTime openedAt,
    DateTime? closedAt,

    /// Rapport Z : entrées, sorties, prélèvements (qui, combien, pourquoi).
    @Default(<CashMovementLine>[]) List<CashMovementLine> movements,
  }) = _CashSession;

  factory CashSession.fromJson(Map<String, dynamic> json) =>
      _$CashSessionFromJson(json);
}

@freezed
abstract class CashMovementLine with _$CashMovementLine {
  const factory CashMovementLine({
    required String type,
    required int amount,
    String? note,
    required String userFullName,
    required DateTime createdAt,
  }) = _CashMovementLine;

  factory CashMovementLine.fromJson(Map<String, dynamic> json) =>
      _$CashMovementLineFromJson(json);
}

@freezed
abstract class SaleLine with _$SaleLine {
  const factory SaleLine({
    required String id,
    required String productId,
    @JsonKey(fromJson: quantityFromJson, toJson: quantityToJson)
    required Quantity quantity,
    required int unitPriceHt,

    /// Prix du tarif au moment de la vente ; différent = prix modifié.
    int? tariffPriceHt,
    required String taxRate,
    required int discountAmount,
    required int lineTotalHt,
    required int lineTaxAmount,
    required int lineTotalTtc,
  }) = _SaleLine;

  factory SaleLine.fromJson(Map<String, dynamic> json) =>
      _$SaleLineFromJson(json);
}

@freezed
abstract class Sale with _$Sale {
  const factory Sale({
    required String id,
    required String number,
    String? invoiceNumber,
    DateTime? invoicedAt,
    required String type,
    required String status,
    String? customerId,

    /// Noms du client et du vendeur, pour l'historique (lecture seule).
    String? customerName,
    @Default('') String sellerName,
    required int totalHt,
    required int totalTax,
    required int totalTtc,
    required int paidAmount,
    required int remainingAmount,
    required List<SaleLine> lines,
    required DateTime soldAt,
    DateTime? cancelledAt,

    /// Échéance d'une vente à crédit.
    DateTime? dueDate,
  }) = _Sale;

  factory Sale.fromJson(Map<String, dynamic> json) => _$SaleFromJson(json);
}

@freezed
abstract class CashSessionPage with _$CashSessionPage {
  const factory CashSessionPage({
    required List<CashSession> data,
    required PageMeta meta,
  }) = _CashSessionPage;

  factory CashSessionPage.fromJson(Map<String, dynamic> json) =>
      _$CashSessionPageFromJson(json);
}

@freezed
abstract class SalePage with _$SalePage {
  const factory SalePage({required List<Sale> data, required PageMeta meta}) =
      _SalePage;

  factory SalePage.fromJson(Map<String, dynamic> json) =>
      _$SalePageFromJson(json);
}

@freezed
abstract class Customer with _$Customer {
  const factory Customer({
    required String id,
    required String name,
    String? phone,
    String? email,
    String? address,
    String? priceTierId,
    String? notes,
    required int creditLimit,
    required int balanceDue,

    /// Total acheté (ventes validées, TTC) et total payé (fiche client, §10) :
    /// un chiffre d'affaires, rendu à l'ADMIN seul (`null` sinon).
    int? totalPurchased,
    int? totalPaid,

    /// Part de la dette dont l'échéance est dépassée.
    @Default(0) int overdueAmount,
    required bool isActive,
  }) = _Customer;

  factory Customer.fromJson(Map<String, dynamic> json) =>
      _$CustomerFromJson(json);
}

@freezed
abstract class CustomerPage with _$CustomerPage {
  const factory CustomerPage({
    required List<Customer> data,
    required PageMeta meta,
  }) = _CustomerPage;

  factory CustomerPage.fromJson(Map<String, dynamic> json) =>
      _$CustomerPageFromJson(json);
}
