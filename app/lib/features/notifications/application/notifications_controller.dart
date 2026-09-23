import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/models/page_meta.dart';
import '../../../data/sync/sync_coordinator.dart';
import '../data/notification_models.dart';
import '../data/notifications_api.dart';

/// Boîte de réception, lue EN LIGNE. Elle n'est pas gardée sur l'appareil : une
/// alerte périmée (« demande à préparer » déjà traitée par un collègue) envoie
/// quelqu'un travailler pour rien.
final notificationsProvider = FutureProvider.autoDispose<NotificationPage>((
  ref,
) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) {
    return const NotificationPage(
      data: [],
      meta: PageMeta(page: 1, limit: 0, total: 0),
      unread: 0,
    );
  }
  ref.watch(serverReachableProvider);
  // Battement du coordinateur de synchro : c'est lui qui fait ARRIVER les
  // alertes pendant qu'on travaille. Sans cette dépendance, la boîte était
  // lue une fois par session et une demande posée après ne s'affichait jamais.
  ref.watch(syncCoordinatorProvider);
  return ref.watch(notificationsApiProvider).list();
});

/// Compteur du badge, tenu à part de la liste : il doit survivre à la fermeture
/// de l'écran et se rafraîchir seul. `0` tant que rien n'est connu — un badge
/// est une promesse, il ne s'invente pas.
class UnreadNotifications extends AsyncNotifier<int> {
  @override
  Future<int> build() async {
    // Déconnecté : ZÉRO, et aucun appel. Sur un poste partagé, le compteur du
    // compte précédent ne doit pas rester affiché le temps d'un aller-retour.
    final userId = ref.watch(currentUserIdProvider);
    if (userId == null) return 0;
    ref.watch(serverReachableProvider);
    // Même battement que la liste : c'est ce qui fait vivre le badge.
    ref.watch(syncCoordinatorProvider);
    final page = await ref.watch(notificationsApiProvider).list(limit: 1);
    return page.unread;
  }

  /// Nombre renvoyé par le serveur après une lecture : on ne décrémente pas
  /// nous-mêmes (deux appareils peuvent lire la même notification).
  void set(int unread) => state = AsyncData(unread);
}

final unreadNotificationsProvider =
    AsyncNotifierProvider<UnreadNotifications, int>(UnreadNotifications.new);
