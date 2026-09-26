import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/business_report_models.dart';
import '../data/business_reports_api.dart';

/// Période demandée par l'écran, en jours révolus. Des raccourcis plutôt qu'un
/// sélecteur de dates : « ce mois-ci » est ce qu'on regarde neuf fois sur dix, et
/// le serveur borne de toute façon à 730 jours.
class ReportRangeController extends Notifier<int> {
  @override
  int build() => 30;

  void set(int days) => state = days;
}

final reportRangeProvider = NotifierProvider<ReportRangeController, int>(
  ReportRangeController.new,
);

/// Bornes envoyées au serveur pour une fenêtre de N jours révolus, aujourd'hui
/// INCLUS — le serveur traite `to` comme inclusif.
({String from, String to}) rangeFor(int days, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final day = DateTime(today.year, today.month, today.day);
  String iso(DateTime value) => value.toIso8601String().substring(0, 10);
  return (from: iso(day.subtract(Duration(days: days - 1))), to: iso(day));
}

final salesReportProvider = FutureProvider.autoDispose<SalesReport>((
  ref,
) async {
  ref.watch(currentUserIdProvider);
  ref.watch(serverReachableProvider);
  final range = rangeFor(ref.watch(reportRangeProvider));
  return ref
      .watch(businessReportsApiProvider)
      .sales(from: range.from, to: range.to);
});

/// Le stock n'a PAS de période : c'est un état, pas un flux. Il ne dépend donc
/// pas de `reportRangeProvider` — changer la fenêtre ne doit pas le relire.
final stockReportProvider = FutureProvider.autoDispose<StockReport>((
  ref,
) async {
  ref.watch(currentUserIdProvider);
  ref.watch(serverReachableProvider);
  return ref.watch(businessReportsApiProvider).stock();
});

final purchasesReportProvider = FutureProvider.autoDispose<PurchasesReport>((
  ref,
) async {
  ref.watch(currentUserIdProvider);
  ref.watch(serverReachableProvider);
  final range = rangeFor(ref.watch(reportRangeProvider));
  return ref
      .watch(businessReportsApiProvider)
      .purchases(from: range.from, to: range.to);
});
