import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../suppliers/application/suppliers_controller.dart';
import '../../receptions/application/receptions_controller.dart';
import '../../receptions/presentation/reception_form.dart';
import '../application/purchases_controller.dart';
import '../data/purchases_models.dart';
import 'purchase_order_form.dart';

/// Droits achats, MIROIRS des guards serveur (`docs/permissions.md`) :
/// créer/modifier = ADMIN|MAGASINIER + purchase.create ; confirmer/annuler =
/// ADMIN + purchase.confirm.
class PurchaseRights {
  PurchaseRights(AuthUser user)
    : canWrite =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('purchase.create'),
      canConfirm = user.hasRole('ADMIN') && user.can('purchase.confirm'),
      canReceive =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('reception.create');

  final bool canWrite;
  final bool canConfirm;
  final bool canReceive;
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: 'Fermer', onPressed: () {}),
      ),
    );
}

StatusTone _tone(PurchaseStatus status) => switch (status) {
  PurchaseStatus.draft => StatusTone.neutral,
  PurchaseStatus.ordered => StatusTone.info,
  PurchaseStatus.confirmed => StatusTone.info,
  PurchaseStatus.partiallyReceived => StatusTone.warn,
  PurchaseStatus.received => StatusTone.ok,
  PurchaseStatus.cancelled => StatusTone.error,
};

class PurchasesScreen extends ConsumerWidget {
  const PurchasesScreen({super.key, required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rights = PurchaseRights(user);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final orders = ref.watch(purchaseOrdersProvider);
    final suppliers = {
      for (final s in ref.watch(supplierSearchProvider('')).value ?? const [])
        s.id: s.name,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rights.canWrite)
          Padding(
            padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () =>
                    openFormPanel<void>(context, const PurchaseOrderForm()),
                icon: const Icon(LucideIcons.plus, size: 17),
                label: const Text('Nouvelle commande'),
              ),
            ),
          ),
        Expanded(
          child: orders.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException ? error.userMessage : '$error',
              onRetry: () => ref.invalidate(purchaseOrdersProvider),
            ),
            data: (items) => items.isEmpty
                ? const ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Aucune commande',
                    message:
                        'Préparez une commande fournisseur : elle sera '
                        'réceptionnée au dépôt.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final o in items)
                        Card(
                          child: ListTile(
                            title: Text(
                              '${o.number} · ${suppliers[o.supplierId] ?? 'Fournisseur'}',
                            ),
                            subtitle: Text(
                              '${o.lines.length} ligne(s) · '
                              '${formatDA(o.totalTtc)} TTC',
                            ),
                            trailing: AmpereBadge(
                              label: o.status.label,
                              tone: _tone(o.status),
                            ),
                            onTap: () => _openActions(context, ref, o, rights),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _openActions(
    BuildContext context,
    WidgetRef ref,
    PurchaseOrder order,
    PurchaseRights rights,
  ) async {
    final editable = order.status.isEditable;
    // Miroir du serveur : on ne réceptionne qu'une commande engagée.
    final receivable =
        order.status == PurchaseStatus.confirmed ||
        order.status == PurchaseStatus.partiallyReceived;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${order.number} — ${order.status.label}'),
        children: [
          if (editable && rights.canWrite)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('edit'),
              child: const Text('Modifier les lignes'),
            ),
          if (order.status == PurchaseStatus.draft && rights.canWrite)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('ordered'),
              child: const Text('Marquer comme envoyée au fournisseur'),
            ),
          if (editable && rights.canConfirm)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('confirm'),
              child: const Text('Confirmer la commande'),
            ),
          // Refusée par le serveur dès qu'une réception existe.
          if ((editable || order.status == PurchaseStatus.confirmed) &&
              rights.canConfirm)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('cancel'),
              child: const Text('Annuler la commande'),
            ),
          if (receivable && rights.canReceive)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('receive'),
              child: const Text('Réceptionner la marchandise'),
            ),
          if (!editable && rights.canReceive)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('receptions'),
              child: const Text('Réceptions enregistrées'),
            ),
          if (!editable)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('view'),
              child: const Text('Voir les lignes'),
            ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;
    if (action == 'receive') {
      await openFormPanel<void>(context, ReceptionForm(order: order));
      return;
    }
    if (action == 'receptions') {
      await _showReceptions(context, ref, order);
      return;
    }
    if (action == 'edit' || action == 'view') {
      await openFormPanel<void>(
        context,
        PurchaseOrderForm(existing: order, readOnly: action == 'view'),
      );
      return;
    }
    if (action == 'cancel') {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Annuler ${order.number} ?'),
          content: const Text(
            'La commande reste dans l’historique avec le statut « Annulée ».',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Garder'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Annuler la commande'),
            ),
          ],
        ),
      );
      if (sure != true || !context.mounted) return;
    }
    final actions = ref.read(purchasesActionsProvider);
    try {
      final updated = await switch (action) {
        'ordered' => actions.markOrdered(order.id),
        'confirm' => actions.confirm(order),
        _ => actions.cancel(order.id),
      };
      if (context.mounted) {
        _snack(context, '${updated.number} : ${updated.status.label}.');
      }
    } on ApiException catch (error) {
      // Version périmée : la liste est relue pour montrer la commande actuelle.
      if (error.statusCode == 409) ref.invalidate(purchaseOrdersProvider);
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  /// Historique : une commande peut avoir plusieurs réceptions partielles.
  Future<void> _showReceptions(
    BuildContext context,
    WidgetRef ref,
    PurchaseOrder order,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Réceptions de ${order.number}'),
        content: SizedBox(
          width: 420,
          child: Consumer(
            builder: (context, ref, _) => ref
                .watch(orderReceptionsProvider(order.id))
                .when(
                  loading: () => const AmpereSkeletonList(rows: 2),
                  error: (error, _) => Text(
                    error is ApiException ? error.userMessage : '$error',
                  ),
                  data: (items) => items.isEmpty
                      ? const Text('Aucune réception pour cette commande.')
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final r in items)
                              ListTile(
                                title: Text(r.number),
                                subtitle: Text(
                                  '${r.lines.length} ligne(s) · '
                                  '${formatDA(r.totalTtc)} TTC',
                                ),
                              ),
                          ],
                        ),
                ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }
}
