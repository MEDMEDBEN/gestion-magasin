import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/offline_documents_notice.dart';
import '../../../ui/widgets/page_kit.dart';
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

/// Filtre de la liste, porté par les tuiles colorées.
enum _Filter { all, inProgress, toValidate, adjusted }

bool _matches(Inventory i, _Filter f) => switch (f) {
  _Filter.all => true,
  _Filter.inProgress => i.status == InventoryStatus.inProgress,
  _Filter.toValidate => i.awaitsValidation,
  _Filter.adjusted => i.validatedAt != null,
};

/// Inventaire (spec §22) : comparer théorique ↔ physique, puis faire valider
/// l'ajustement par l'administrateur — seule étape qui touche le stock.
///
/// Refonte du 2026-10-13 (MEDMEDBEN) : le déroulé est toujours affiché, les
/// deux façons de compter sont des boutons expliqués, un comptage en cours se
/// reprend d'un geste, et la couleur dit où en est chaque inventaire.
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final rights = InventoryRights(widget.user);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final inventories = ref.watch(inventoriesProvider);

    return inventories.when(
      loading: () => const AmpereSkeletonList(rows: 5),
      error: (error, _) => ScreenStateView(
        status: error is ApiException && error.isOffline
            ? ScreenStatus.offline
            : ScreenStatus.error,
        message: error is ApiException ? error.userMessage : '$error',
        onRetry: () => ref.invalidate(inventoriesProvider),
      ),
      data: (list) {
        final items = list.items;
        int count(_Filter f) => items.where((i) => _matches(i, f)).length;
        final running = items
            .where((i) => i.status == InventoryStatus.inProgress)
            .toList();
        final toValidate = count(_Filter.toValidate);
        final shown = items.where((i) => _matches(i, _filter)).toList();
        final step = running.isNotEmpty
            ? 1
            : toValidate > 0
            ? 3
            : 0;

        StatTile tile(
          _Filter f,
          IconData icon,
          String label,
          StatusTone tone,
        ) => StatTile(
          icon: icon,
          label: label,
          value: '${count(f)}',
          tone: tone,
          selected: _filter == f,
          onTap: () => setState(() => _filter = _filter == f ? _Filter.all : f),
        );

        return ListView(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 24),
          children: [
            GuideSteps(
              title: 'COMMENT SE PASSE UN INVENTAIRE',
              current: step,
              steps: [
                (
                  'Lancer',
                  'Tournant : quelques produits, une étagère. Complet : tout '
                      'un lieu. Le stock théorique est noté à cet instant.',
                ),
                (
                  'Compter',
                  'Scannez ou cherchez chaque produit, saisissez la quantité '
                      'réelle. Tout est gardé au fur et à mesure.',
                ),
                (
                  'Terminer',
                  'Les écarts apparaissent en couleur : vérifiez-les, puis '
                      'terminez le comptage.',
                ),
                (
                  'Valider les écarts',
                  rights.canValidate
                      ? 'Vous validez : le stock prend les quantités comptées.'
                      : 'L’administrateur valide : le stock prend les '
                            'quantités comptées.',
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (rights.canValidate && toValidate > 0) ...[
              AmpereInlineAlert(
                tone: StatusTone.warn,
                icon: LucideIcons.clipboardList,
                message:
                    '$toValidate comptage(s) terminé(s) attendent votre '
                    'validation pour corriger le stock.',
                action: TextButton(
                  onPressed: () => setState(() => _filter = _Filter.toValidate),
                  child: const Text('Voir'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (rights.canCount) ...[
              ActionGrid(
                children: [
                  for (final i in running.take(2))
                    ActionTile(
                      icon: LucideIcons.play,
                      title: 'Reprendre ${i.number}',
                      subtitle:
                          '${i.lines.length - i.countedCount} produit(s) '
                          'restent à compter',
                      tone: StatusTone.warn,
                      prominent: true,
                      onTap: () => _count(context, i, rights),
                    ),
                  ActionTile(
                    icon: LucideIcons.listChecks,
                    title: 'Comptage tournant',
                    subtitle: 'Quelques produits ou une étagère : 5 minutes.',
                    tone: StatusTone.info,
                    prominent: running.isEmpty,
                    onTap: () => _start(context, rights, InventoryType.cycle),
                  ),
                  ActionTile(
                    icon: LucideIcons.clipboardCheck,
                    title: 'Inventaire complet',
                    subtitle: 'Tous les produits d’un lieu (magasin ou dépôt).',
                    tone: StatusTone.neutral,
                    onTap: () => _start(context, rights, InventoryType.full),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (items.isEmpty)
              const AmpereInlineAlert(
                tone: StatusTone.info,
                icon: LucideIcons.info,
                message:
                    'Aucun inventaire pour l’instant. Conseil : commencez par '
                    'un comptage tournant des produits les plus vendus — '
                    'c’est la seule façon de corriger une quantité.',
              )
            else ...[
              StatGrid(
                children: [
                  tile(
                    _Filter.all,
                    LucideIcons.clipboardList,
                    'Tous',
                    StatusTone.neutral,
                  ),
                  tile(
                    _Filter.inProgress,
                    LucideIcons.timer,
                    'En cours',
                    StatusTone.info,
                  ),
                  tile(
                    _Filter.toValidate,
                    LucideIcons.triangleAlert,
                    'Attendent validation',
                    StatusTone.warn,
                  ),
                  tile(
                    _Filter.adjusted,
                    LucideIcons.circleCheck,
                    'Stock ajusté',
                    StatusTone.ok,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'HISTORIQUE DES INVENTAIRES',
                      style: AmpereType.label.copyWith(
                        color: AmpereColors.of(context).ink3,
                      ),
                    ),
                  ),
                  // Même garde que la liste affichée ici (`inventory.create`).
                  if (rights.canCount)
                    ExportButton(
                      targets: [
                        ExportTarget(
                          'Inventaires et lignes comptées',
                          ref.read(inventoryApiProvider).exportInventories,
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 8),
              OfflineDocumentsNotice(
                cachedAt: list.cachedAt,
                actionsQueue: false,
              ),
              if (shown.isEmpty)
                const ScreenStateView(
                  status: ScreenStatus.empty,
                  title: 'Rien dans cette catégorie',
                )
              else
                for (final i in shown)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _InventoryCard(
                      inventory: i,
                      onTap: () => _open(context, i, rights),
                    ),
                  ),
            ],
          ],
        );
      },
    );
  }

  /// Lancement puis, AUSSITÔT, la saisie : pas de retour à la liste.
  Future<void> _start(
    BuildContext context,
    InventoryRights rights,
    InventoryType type,
  ) async {
    final inventory = await openFormPanel<Inventory>(
      context,
      InventoryStartForm(initialType: type),
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

/// Un inventaire de la liste : état en couleur, avancement du comptage.
class _InventoryCard extends StatelessWidget {
  const _InventoryCard({required this.inventory, required this.onTap});

  final Inventory inventory;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final tone = _tone(inventory);
    final total = inventory.lines.length;
    final progress = total == 0 ? 0.0 : inventory.countedCount / total;
    final gaps = inventory.gaps.length;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: tone.foreground(colors).withValues(alpha: 0.45),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    inventory.type == InventoryType.cycle
                        ? LucideIcons.listChecks
                        : LucideIcons.clipboardCheck,
                    size: 18,
                    color: tone.foreground(colors),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    inventory.number,
                    style: AmpereType.rowTitle.copyWith(color: colors.ink),
                  ),
                  Expanded(
                    child: Text(
                      ' · ${inventory.type.label}'
                      '${inventory.zone == null ? '' : ' · ${inventory.zone}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.meta.copyWith(color: colors.ink3),
                    ),
                  ),
                  AmpereBadge(label: _badge(inventory), tone: tone),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _summary(inventory),
                style: AmpereType.meta.copyWith(color: colors.ink2),
              ),
              if (inventory.status == InventoryStatus.inProgress) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    color: colors.info,
                    backgroundColor: colors.infoBg,
                  ),
                ),
              ] else if (gaps > 0 && inventory.validatedAt == null) ...[
                const SizedBox(height: 6),
                Text(
                  '$gaps écart(s) à faire valider',
                  style: AmpereType.bodyStrong.copyWith(color: colors.warn),
                ),
              ],
            ],
          ),
        ),
      ),
    );
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
