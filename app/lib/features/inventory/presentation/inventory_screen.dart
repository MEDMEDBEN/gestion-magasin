import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/inventory_controller.dart';
import '../data/inventory_models.dart';
import 'inventory_count_form.dart';
import 'inventory_start_form.dart';

/// Droits inventaire, MIROIRS des guards serveur (`docs/permissions.md`) :
/// lancer et compter = ADMIN|MAGASINIER ; valider l'ajustement = ADMIN SEUL.
class InventoryRights {
  InventoryRights(AuthUser user)
    : canCount =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('inventory.create'),
      canValidate = user.hasRole('ADMIN') && user.can('inventory.validate');

  final bool canCount;
  final bool canValidate;
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

/// Un inventaire validé est clos ; un comptage terminé attend l'admin ; un
/// écart non traité est ce qu'il faut voir en premier.
StatusTone _tone(Inventory inventory) {
  if (inventory.validatedAt != null) return StatusTone.ok;
  if (inventory.awaitsValidation) return StatusTone.warn;
  return StatusTone.info;
}

String _badge(Inventory inventory) {
  if (inventory.validatedAt != null) return 'Ajusté';
  if (inventory.awaitsValidation) return 'À valider';
  return inventory.status.label;
}

/// Résumé lisible : avancement du comptage, puis écarts constatés.
String _summary(Inventory inventory) {
  final total = inventory.lines.length;
  if (inventory.status == InventoryStatus.inProgress) {
    return '${inventory.countedCount} sur $total produit(s) comptés';
  }
  final gaps = inventory.gaps.length;
  final scope = inventory.type == InventoryType.cycle
      ? '${inventory.type.label.toLowerCase()}${inventory.zone == null ? '' : ' · ${inventory.zone}'}'
      : inventory.type.label.toLowerCase();
  return gaps == 0
      ? '$total produit(s) comptés · aucun écart · $scope'
      : '$gaps écart(s) sur $total produit(s) · $scope';
}

/// Inventaire (spec §22) : comparer théorique ↔ physique, puis faire valider
/// l'ajustement par l'administrateur — seule étape qui touche le stock.
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key, required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rights = InventoryRights(user);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final inventories = ref.watch(inventoriesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rights.canCount)
          Padding(
            padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () =>
                    openFormPanel<void>(context, const InventoryStartForm()),
                icon: const Icon(LucideIcons.plus, size: 17),
                label: const Text('Lancer un inventaire'),
              ),
            ),
          ),
        Expanded(
          child: inventories.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException ? error.userMessage : '$error',
              onRetry: () => ref.invalidate(inventoriesProvider),
            ),
            data: (items) => items.isEmpty
                ? const ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Aucun inventaire',
                    message:
                        'Comptez le stock réel et faites valider les écarts : '
                        'c’est la seule façon de corriger une quantité.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final i in items)
                        Card(
                          child: ListTile(
                            title: Text(i.number),
                            subtitle: Text(_summary(i)),
                            trailing: AmpereBadge(
                              label: _badge(i),
                              tone: _tone(i),
                            ),
                            onTap: () => _openActions(context, ref, i, rights),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// Actions proposées = celles que le serveur accepterait à cet instant.
  Future<void> _openActions(
    BuildContext context,
    WidgetRef ref,
    Inventory inventory,
    InventoryRights rights,
  ) async {
    final open = inventory.status == InventoryStatus.inProgress;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${inventory.number} — ${_badge(inventory)}'),
        children: [
          if (open && rights.canCount)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('count'),
              child: Text(
                inventory.countedCount == 0
                    ? 'Saisir le comptage'
                    : 'Reprendre le comptage',
              ),
            ),
          if (inventory.awaitsValidation && rights.canValidate)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('validate'),
              child: const Text('Valider les ajustements'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('lines'),
            child: const Text('Voir les écarts'),
          ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;

    if (action == 'count') {
      await openFormPanel<void>(
        context,
        InventoryCountForm(inventory: inventory),
      );
      return;
    }
    if (action == 'lines') {
      await _showLines(context, inventory);
      return;
    }

    final gaps = inventory.gaps.length;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Valider ${inventory.number} ?'),
        content: Text(
          gaps == 0
              ? 'Aucun écart : le stock ne bougera pas, l’inventaire sera clos.'
              : '$gaps ligne(s) en écart. Le stock sera corrigé d’autant, et '
                    'chaque correction laissera un mouvement daté à ton nom.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Revenir'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;
    try {
      final updated = await ref
          .read(inventoryActionsProvider)
          .validate(inventory.id);
      if (context.mounted) {
        _snack(context, '${updated.number} : stock ajusté.');
      }
    } on ApiException catch (error) {
      // Comptage périmé ou état changé : on relit pour montrer la réalité.
      if (error.statusCode == 409) ref.invalidate(inventoriesProvider);
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  /// Le détail ligne à ligne : théorique, compté, écart.
  Future<void> _showLines(BuildContext context, Inventory inventory) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Écarts de ${inventory.number}'),
        content: SizedBox(
          width: 460,
          child: Consumer(
            builder: (context, ref, _) {
              final products = {
                for (final p
                    in ref.watch(activeProductsProvider).value ??
                        const <Product>[])
                  p.id: p.name,
              };
              final colors = AmpereColors.of(context);
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final l in inventory.lines)
                      ListTile(
                        dense: true,
                        title: Text(products[l.productId] ?? 'Produit'),
                        subtitle: Text(
                          'Théorique ${formatQuantity(l.theoreticalQuantity)} · '
                          'compté ${l.countedQuantity == null ? '—' : formatQuantity(l.countedQuantity!)}',
                        ),
                        trailing: Text(
                          l.state == InventoryLineState.gap
                              ? formatQuantity(l.difference)
                              : '0',
                          style: TextStyle(
                            color: l.state == InventoryLineState.gap
                                ? colors.warn
                                : colors.ink3,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
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
