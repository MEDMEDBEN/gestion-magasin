import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/money.dart';

part 'dashboard_models.freezed.dart';
part 'dashboard_models.g.dart';

/// Résumé d'accueil (spec §21). Un bloc **`null`** = le compte n'a pas le droit
/// de le voir : l'écran n'affiche alors RIEN, jamais un zéro — un « 0 alerte »
/// mensonger est pire qu'une case absente. C'est le serveur qui décide.
@freezed
abstract class DashboardSummary with _$DashboardSummary {
  const factory DashboardSummary({
    required String day,
    DashboardSales? sales,
    DashboardStock? stock,
    DashboardTransfers? transfers,
    DashboardPurchases? purchases,
    DashboardCustomers? customers,
    DashboardSuppliers? suppliers,
    DashboardTasks? tasks,
  }) = _DashboardSummary;

  factory DashboardSummary.fromJson(Map<String, dynamic> json) =>
      _$DashboardSummaryFromJson(json);
}

@freezed
abstract class DashboardSales with _$DashboardSales {
  const factory DashboardSales({
    required int count,
    required Money revenueTtc,
  }) = _DashboardSales;

  factory DashboardSales.fromJson(Map<String, dynamic> json) =>
      _$DashboardSalesFromJson(json);
}

@freezed
abstract class DashboardLowStock with _$DashboardLowStock {
  const factory DashboardLowStock({
    required String productId,
    required String name,
    required String quantity,
    required String minThreshold,
  }) = _DashboardLowStock;

  factory DashboardLowStock.fromJson(Map<String, dynamic> json) =>
      _$DashboardLowStockFromJson(json);
}

@freezed
abstract class DashboardStock with _$DashboardStock {
  const factory DashboardStock({
    required int lowCount,
    required int outOfStockCount,
    @Default(<DashboardLowStock>[]) List<DashboardLowStock> low,
  }) = _DashboardStock;

  factory DashboardStock.fromJson(Map<String, dynamic> json) =>
      _$DashboardStockFromJson(json);
}

@freezed
abstract class DashboardTransfers with _$DashboardTransfers {
  const factory DashboardTransfers({
    required int toPrepare,
    required int inTransit,
  }) = _DashboardTransfers;

  factory DashboardTransfers.fromJson(Map<String, dynamic> json) =>
      _$DashboardTransfersFromJson(json);
}

@freezed
abstract class DashboardPurchases with _$DashboardPurchases {
  const factory DashboardPurchases({required int toReceive}) =
      _DashboardPurchases;

  factory DashboardPurchases.fromJson(Map<String, dynamic> json) =>
      _$DashboardPurchasesFromJson(json);
}

@freezed
abstract class DashboardCustomers with _$DashboardCustomers {
  const factory DashboardCustomers({
    required Money debt,
    required Money overdue,
  }) = _DashboardCustomers;

  factory DashboardCustomers.fromJson(Map<String, dynamic> json) =>
      _$DashboardCustomersFromJson(json);
}

@freezed
abstract class DashboardSuppliers with _$DashboardSuppliers {
  const factory DashboardSuppliers({required Money debt}) = _DashboardSuppliers;

  factory DashboardSuppliers.fromJson(Map<String, dynamic> json) =>
      _$DashboardSuppliersFromJson(json);
}

@freezed
abstract class DashboardTasks with _$DashboardTasks {
  const factory DashboardTasks({required int open, required int late}) =
      _DashboardTasks;

  factory DashboardTasks.fromJson(Map<String, dynamic> json) =>
      _$DashboardTasksFromJson(json);
}
