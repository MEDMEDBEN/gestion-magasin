import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/models/page_meta.dart';
import '../../../data/sync/sync_coordinator.dart';
import '../data/replenishment_api.dart';
import '../data/replenishment_models.dart';

/// Ce qu'on regarde : tout ce qui est à racheter, ou seulement les ruptures.
typedef ReplenishmentFilter = ({bool outOfStockOnly});

/// La liste « à racheter », lue EN LIGNE et rafraîchie au battement de synchro.
///
/// Rien n'est gardé sur l'appareil, volontairement : une liste d'achats périmée
/// ferait commander ce qui vient d'être réceptionné. Contrairement aux écrans du
/// dépôt (n°14), personne n'en a besoin sans réseau — on commande depuis le
/// bureau.
final replenishmentProvider = FutureProvider.autoDispose
    .family<ReplenishmentPage, ReplenishmentFilter>((ref, filter) async {
      final userId = ref.watch(currentUserIdProvider);
      if (userId == null) {
        return const ReplenishmentPage(
          data: [],
          meta: PageMeta(page: 1, limit: 0, total: 0),
        );
      }
      ref.watch(serverReachableProvider);
      ref.watch(syncCoordinatorProvider);
      return ref
          .watch(replenishmentApiProvider)
          .list(outOfStockOnly: filter.outOfStockOnly);
    });
