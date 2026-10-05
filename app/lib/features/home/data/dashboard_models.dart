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

/// CA TTC d'une journée d'Alger, net des retours (peut être négatif).
@freezed
abstract class DashboardDay with _$DashboardDay {
  const factory DashboardDay({required String day, required Money revenueTtc}) =
      _DashboardDay;

  factory DashboardDay.fromJson(Map<String, dynamic> json) =>
      _$DashboardDayFromJson(json);
}

/// Produit le plus vendu sur 30 jours (graphique de l'accueil, 2026-10-05).
@freezed
abstract class DashboardTopProduct with _$DashboardTopProduct {
  const factory DashboardTopProduct({
    required String productId,
    required String name,
    required Money revenueTtc,
    required String quantity,
  }) = _DashboardTopProduct;

  factory DashboardTopProduct.fromJson(Map<String, dynamic> json) =>
      _$DashboardTopProductFromJson(json);
}

@freezed
abstract class DashboardSales with _$DashboardSales {
  const factory DashboardSales({
    required int count,
    required Money revenueTtc,

    /// 7 derniers jours, aujourd'hui en dernier (P1 bis n°21m).
    @Default(<DashboardDay>[]) List<DashboardDay> last7Days,

    /// 30 derniers jours, même ordre (courbe de l'accueil, 2026-10-05).
    @Default(<DashboardDay>[]) List<DashboardDay> last30Days,

    /// 5 meilleurs produits sur 30 jours, même cloisonnement.
    @Default(<DashboardTopProduct>[]) List<DashboardTopProduct> topProducts,
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

    /// Produits au-dessus de leur seuil (anneau de l'état du stock).
    @Default(0) int okCount,
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
