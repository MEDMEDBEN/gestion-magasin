import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/offline_documents_notice.dart';
import '../../../ui/widgets/export_button.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/inventory_controller.dart';
import '../data/inventory_api.dart';
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

  /// Miroir du serveur (comptage et `DELETE /inventories/:id`) : jamais un
  /// inventaire ajusté ; un comptage terminé, l'admin seul (le compteur ne
  /// réécrit ni n'efface des écarts constatés).
  bool canModify(Inventory i) =>
      i.validatedAt == null &&
      (i.status == InventoryStatus.inProgress ? canCount : canValidate);
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
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Même garde que la liste affichée ici (`inventory.create`).
              if (rights.canCount) ...[
                ExportButton(
                  targets: [
                    ExportTarget(
                      'Inventaires et lignes comptées',
                      ref.read(inventoryApiProvider).exportInventories,
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: () => _start(context, rights),
                  icon: const Icon(LucideIcons.plus, size: 17),
                  label: const Text('Nouvel inventaire'),
                ),
              ],
            ],
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
            data: (list) => list.items.isEmpty
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
                      OfflineDocumentsNotice(
                        cachedAt: list.cachedAt,
                        actionsQueue: false,
                      ),
                      for (final i in list.items)
                        Card(
                          child: ListTile(
                            title: Text(i.number),
                            subtitle: Text(_summary(i)),
                            trailing: AmpereBadge(
                              label: _badge(i),
                              tone: _tone(i),
                            ),
                            onTap: () => _open(context, ref, i, rights),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// Lancement puis, AUSSITÔT, la saisie : pas de retour à la liste.
  Future<void> _start(BuildContext context, InventoryRights rights) async {
    final inventory = await openFormPanel<Inventory>(
      context,
      const InventoryStartForm(),
    );
    if (inventory == null || !context.mounted) return;
    await _count(context, inventory, rights);
  }

  Future<void> _count(
    BuildContext context,
    Inventory inventory,
    InventoryRights rights,
  ) => openFormPanel<void>(
    context,
    InventoryCountForm(
      inventory: inventory,
      canAdjust: rights.canValidate,
      canDelete: rights.canModify(inventory),
    ),
  );

  /// En cours : directement la saisie. Sinon, sa fiche (écarts + actions que
  /// le serveur accepterait à cet instant).
  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    Inventory inventory,
    InventoryRights rights,
  ) async {
    if (inventory.status == InventoryStatus.inProgress && rights.canCount) {
      return _count(context, inventory, rights);
    }
    final action = await showDialog<String>(
      context: context,
      builder: (context) => _InventoryDetail(
        inventory: inventory,
        canModify: rights.canModify(inventory),
        canAdjust: inventory.awaitsValidation && rights.canValidate,
        canDelete: rights.canModify(inventory),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'modify':
        await _count(context, inventory, rights);
      case 'adjust':
        await adjustInventory(context, ref, inventory);
      case 'delete':
        await deleteInventory(context, ref, inventory);
    }
  }
}

/// Fiche d'un inventaire : chaque produit, théorique, compté, écart (les écarts
/// d'abord), puis Modifier / Ajuster le stock / Supprimer.
class _InventoryDetail extends ConsumerWidget {
  const _InventoryDetail({
    required this.inventory,
    required this.canModify,
    required this.canAdjust,
    required this.canDelete,
  });

  final Inventory inventory;
  final bool canModify;
  final bool canAdjust;
  final bool canDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final products = {
      for (final p
          in ref.watch(activeProductsProvider).value ?? const <Product>[])
        p.id: p.name,
    };
    final lines = [...inventory.lines]
      ..sort(
        (a, b) => (b.state == InventoryLineState.gap ? 1 : 0).compareTo(
          a.state == InventoryLineState.gap ? 1 : 0,
        ),
      );
    final pop = Navigator.of(context).pop;
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(inventory.number)),
          AmpereBadge(label: _badge(inventory), tone: _tone(inventory)),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_summary(inventory)),
            if (inventory.validatedAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Stock ajusté : cet inventaire est figé. Pour corriger, '
                  'faites-en un nouveau.',
                  style: TextStyle(color: colors.ink3),
                ),
              ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final l in lines)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
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
            ),
          ],
        ),
      ),
      actions: [
        if (canDelete)
          AmpereDangerButton(
            icon: LucideIcons.trash2,
            label: 'Supprimer',
            onPressed: () => pop('delete'),
          ),
        if (canModify)
          OutlinedButton.icon(
            onPressed: () => pop('modify'),
            icon: const Icon(LucideIcons.pencil, size: 16),
            label: const Text('Modifier'),
          ),
        if (canAdjust)
          FilledButton(
            onPressed: () => pop('adjust'),
            child: const Text('Ajuster le stock'),
          ),
        TextButton(onPressed: () => pop(), child: const Text('Fermer')),
      ],
    );
  }
}
