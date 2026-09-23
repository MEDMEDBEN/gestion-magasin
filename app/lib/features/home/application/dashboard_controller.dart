import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/dashboard_api.dart';
import '../data/dashboard_models.dart';

/// Résumé d'accueil du compte connecté, lu EN LIGNE.
///
/// Il n'est pas gardé sur l'appareil : un tableau de bord périmé donnerait un
/// CA et des alertes faux, ce qu'aucun bandeau ne rachète. Hors réseau, l'écran
/// le dit et propose les raccourcis, qui marchent hors ligne (la vente le fait
/// déjà). Relu au RETOUR du réseau.
final dashboardSummaryProvider = FutureProvider.autoDispose<DashboardSummary>((
  ref,
) async {
  ref.watch(currentUserIdProvider);
  ref.watch(serverReachableProvider);
  return ref.watch(dashboardApiProvider).summary();
});
