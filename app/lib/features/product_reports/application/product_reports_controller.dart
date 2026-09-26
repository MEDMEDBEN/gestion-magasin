import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/models/page_meta.dart';
import '../data/product_report_models.dart';
import '../data/product_reports_api.dart';

/// Nombre de jours choisi à l'écran. `Notifier` et non `StateProvider` :
/// celui-ci n'existe plus en Riverpod 3, et le projet porte déjà tous ses états
/// d'écran ainsi (filtre catalogue, filtre audit).
class DaysController extends Notifier<int> {
  DaysController(this._initial);

  final int _initial;

  @override
  int build() => _initial;

  void set(int days) => state = days;
}

/// Seuil de dormance, en jours. Les valeurs proposées à l'écran sont dans les
/// bornes du serveur (7 à 730) : un bouton qui provoquerait un 400 serait un piège.
final dormantDaysProvider = NotifierProvider<DaysController, int>(
  () => DaysController(120),
);

/// Fenêtre d'analyse de la demande, en jours.
final demandDaysProvider = NotifierProvider<DaysController, int>(
  () => DaysController(30),
);

/// Produits dormants. Lu EN LIGNE : un rapport est une photo de l'instant, le
/// garder sur l'appareil ferait décider sur des chiffres périmés.
///
/// Pas de rafraîchissement au battement de synchro, contrairement aux listes de
/// travail : rien n'y est urgent, et la requête parcourt tout le catalogue.
final dormantProductsProvider = FutureProvider.autoDispose<DormantProductPage>((
  ref,
) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) {
    return const DormantProductPage(
      data: [],
      meta: PageMeta(page: 1, limit: 0, total: 0),
    );
  }
  ref.watch(serverReachableProvider);
  return ref
      .watch(productReportsApiProvider)
      .dormant(days: ref.watch(dormantDaysProvider));
});

final productDemandProvider = FutureProvider.autoDispose<ProductDemand>((
  ref,
) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return const ProductDemand();
  ref.watch(serverReachableProvider);
  return ref
      .watch(productReportsApiProvider)
      .demand(days: ref.watch(demandDaysProvider));
});
