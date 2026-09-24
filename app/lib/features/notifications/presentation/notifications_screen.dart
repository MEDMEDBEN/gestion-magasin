import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/navigation.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../application/notifications_controller.dart';
import '../data/notification_models.dart';
import '../data/notifications_api.dart';

/// Écran où va la destination visée par une alerte. `null` : l'opération n'a
/// pas d'écran dédié (ou il est fermé à ce compte) — l'alerte reste alors
/// informative, sans bouton mort.
String? destinationFor(NotificationTarget? target) => switch (target) {
  NotificationTarget.transfer => 'Transferts',
  NotificationTarget.reception || NotificationTarget.purchaseOrder => 'Achats',
  NotificationTarget.inventory => 'Inventaire',
  NotificationTarget.sale || NotificationTarget.quote => 'Vente',
  NotificationTarget.product => 'Catalogue',
  NotificationTarget.conversation => 'Messages',
  _ => null,
};

/// Ton d'une alerte : ce qui est en retard ou en écart doit se voir en premier.
StatusTone toneOf(AppNotification notification) {
  if (notification.priority == NotificationPriority.urgent ||
      notification.priority == NotificationPriority.high) {
    return StatusTone.error;
  }
  return switch (notification.type) {
    NotificationKind.outOfStock ||
    NotificationKind.customerOverdue ||
    NotificationKind.taskLate ||
    NotificationKind.discrepancy => StatusTone.error,
    NotificationKind.lowStock ||
    NotificationKind.partialReception ||
    NotificationKind.supplierLate => StatusTone.warn,
    _ => StatusTone.info,
  };
}

/// Boîte de réception (spec §18) : ce qui me concerne, le plus récent d'abord.
///
/// Toucher une alerte la marque lue ET ouvre l'opération : une notification est
/// faite pour être traitée, pas seulement effacée.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key, required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final inbox = ref.watch(notificationsProvider);
    final open = destinationsFor(user).map((d) => d.label).toSet();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (inbox.value?.unread case final unread? when unread > 0)
          Padding(
            padding: EdgeInsets.fromLTRB(margin, 14, margin, 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  final left = await ref
                      .read(notificationsApiProvider)
                      .markAllRead();
                  ref.read(unreadNotificationsProvider.notifier).set(left);
                  ref.invalidate(notificationsProvider);
                },
                child: Text('Tout marquer lu ($unread)'),
              ),
            ),
          ),
        Expanded(
          child: inbox.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException
                  ? error.userMessage
                  : 'Vos notifications n’ont pas pu être chargées.',
              onRetry: () => ref.invalidate(notificationsProvider),
            ),
            data: (page) => page.data.isEmpty
                ? const ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Aucune notification',
                    message:
                        'Les demandes du magasin, les transferts et les '
                        'réceptions viendront s’afficher ici.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final item in page.data)
                        _NotificationTile(item: item, open: open),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _NotificationTile extends ConsumerWidget {
  const _NotificationTile({required this.item, required this.open});

  final AppNotification item;
  final Set<String> open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final target = destinationFor(item.operationType);
    final reachable = target != null && open.contains(target);

    return Card(
      // Une non lue se distingue d'un coup d'œil, sans avoir à lire la date.
      color: item.isRead ? null : colors.surface2,
      child: ListTile(
        minTileHeight: AmpereGeometry.listRowMin,
        leading: AmpereBadge(label: item.type.label, tone: toneOf(item)),
        title: Text(item.title),
        subtitle: Text(
          [?item.body, formatDateTime(item.createdAt)].join(' · '),
        ),
        onTap: () async {
          if (!item.isRead) {
            final left = await ref
                .read(notificationsApiProvider)
                .markRead(item.id);
            ref.read(unreadNotificationsProvider.notifier).set(left);
            ref.invalidate(notificationsProvider);
          }
          // Traiter, pas seulement effacer : on ouvre l'écran de l'opération
          // quand ce compte y a droit.
          if (reachable) goToDestination(ref, target);
        },
      ),
    );
  }
}
