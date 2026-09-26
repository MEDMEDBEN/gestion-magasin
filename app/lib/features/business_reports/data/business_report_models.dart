import 'package:freezed_annotation/freezed_annotation.dart';

part 'business_report_models.freezed.dart';
part 'business_report_models.g.dart';

/// Période couverte par un rapport, telle que le SERVEUR l'a appliquée — et non
/// telle que l'écran l'a demandée : les bornes sont normalisées côté serveur.
@freezed
abstract class ReportPeriod with _$ReportPeriod {
  const factory ReportPeriod({
    required String from,
    required String to,
    @Default(0) int days,
  }) = _ReportPeriod;

  factory ReportPeriod.fromJson(Map<String, dynamic> json) =>
      _$ReportPeriodFromJson(json);
}

/// Montants en centimes entiers (règle 4). `costHt` et `marginHt` sont
/// NULLABLES : coût inconnu ne veut pas dire coût nul. La marge ne porte que
/// sur le CA des produits au coût connu ; `uncostedRevenueHt` est le reste.
@freezed
abstract class SalesReportTotals with _$SalesReportTotals {
  const factory SalesReportTotals({
    @Default(0) int count,
    @Default(0) int revenueHt,
    @Default(0) int taxAmount,
    @Default(0) int revenueTtc,
    @Default(0) int discountAmount,
    int? costHt,
    int? marginHt,
    @Default(0) int uncostedRevenueHt,
  }) = _SalesReportTotals;

  factory SalesReportTotals.fromJson(Map<String, dynamic> json) =>
      _$SalesReportTotalsFromJson(json);
}

@freezed
abstract class SalesByDay with _$SalesByDay {
  const factory SalesByDay({
    required String date,
    @Default(0) int count,
    @Default(0) int revenueHt,
  }) = _SalesByDay;

  factory SalesByDay.fromJson(Map<String, dynamic> json) =>
      _$SalesByDayFromJson(json);
}

@freezed
abstract class SalesByCategory with _$SalesByCategory {
  const factory SalesByCategory({
    String? categoryId,
    required String categoryName,
    @Default(0) int revenueHt,
    @Default('0') String quantity,
  }) = _SalesByCategory;

  factory SalesByCategory.fromJson(Map<String, dynamic> json) =>
      _$SalesByCategoryFromJson(json);
}

@freezed
abstract class SalesReport with _$SalesReport {
  const factory SalesReport({
    required ReportPeriod period,
    required SalesReportTotals totals,
    @Default([]) List<SalesByDay> byDay,
    @Default([]) List<SalesByCategory> byCategory,
  }) = _SalesReport;

  factory SalesReport.fromJson(Map<String, dynamic> json) =>
      _$SalesReportFromJson(json);
}

@freezed
abstract class StockByLocation with _$StockByLocation {
  const factory StockByLocation({
    required String locationId,
    required String locationName,
    required String locationType,
    @Default(0) int referenceCount,
    int? valueHt,
  }) = _StockByLocation;

  factory StockByLocation.fromJson(Map<String, dynamic> json) =>
      _$StockByLocationFromJson(json);
}

@freezed
abstract class StockReport with _$StockReport {
  const factory StockReport({
    @Default(0) int referenceCount,
    int? valueHt,
    @Default(0) int withoutCostCount,
    @Default(0) int lowCount,
    @Default(0) int outOfStockCount,
    @Default([]) List<StockByLocation> byLocation,
  }) = _StockReport;

  factory StockReport.fromJson(Map<String, dynamic> json) =>
      _$StockReportFromJson(json);
}

@freezed
abstract class PurchasesBySupplier with _$PurchasesBySupplier {
  const factory PurchasesBySupplier({
    required String supplierId,
    required String supplierName,
    @Default(0) int orderCount,
    @Default(0) int orderedHt,
    @Default(0) int receivedHt,
  }) = _PurchasesBySupplier;

  factory PurchasesBySupplier.fromJson(Map<String, dynamic> json) =>
      _$PurchasesBySupplierFromJson(json);
}

@freezed
abstract class PurchasesReport with _$PurchasesReport {
  const factory PurchasesReport({
    required ReportPeriod period,
    @Default(0) int orderCount,
    @Default(0) int orderedHt,
    @Default(0) int receivedHt,
    @Default(0) int receptionCount,
    @Default([]) List<PurchasesBySupplier> bySupplier,
  }) = _PurchasesReport;

  factory PurchasesReport.fromJson(Map<String, dynamic> json) =>
      _$PurchasesReportFromJson(json);
}
