import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/catalog_controller.dart';

/// Recherche DEMANDÉE (assistant : « chof câble ») appliquée au champ de
/// recherche d'un écran du catalogue — qu'il s'ouvre pour l'occasion ou qu'il
/// soit déjà ouvert (audit du 2026-10-06). Une seule implémentation pour
/// Catalogue et Stock.
mixin FollowsRequestedSearch<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// Le champ de recherche de l'écran.
  TextEditingController get searchField;

  @override
  void initState() {
    super.initState();
    // Écran ouvert PAR la demande : après la construction (un provider ne
    // se modifie pas pendant un build).
    Future.microtask(_apply);
  }

  /// À appeler dans `build` : un écran DÉJÀ ouvert suit aussi la demande.
  void followRequestedSearch() {
    ref.listen(requestedSearchProvider, (_, asked) {
      if (asked != null) Future.microtask(_apply);
    });
  }

  void _apply() {
    if (!mounted) return;
    final asked = ref.read(requestedSearchProvider.notifier).take();
    if (asked == null) return;
    searchField.text = asked;
    ref.read(productFilterProvider.notifier).setSearch(asked);
  }
}
