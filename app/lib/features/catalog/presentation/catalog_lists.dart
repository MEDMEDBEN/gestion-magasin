import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/catalog_controller.dart';
import '../data/catalog_models.dart';

/// Catégories en arbre à deux niveaux (ADMIN). Même mise en page desktop et
/// mobile : une liste courte, lignes tactiles.
class CategoriesList extends ConsumerWidget {
  const CategoriesList({
    super.key,
    required this.margin,
    required this.onCreate,
    required this.onEdit,
    required this.onAddChild,
  });

  final double margin;
  final VoidCallback onCreate;
  final void Function(ProductCategory category) onEdit;
  final void Function(ProductCategory root) onAddChild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    return _Section(
      margin: margin,
      createLabel: 'Nouvelle catégorie',
      onCreate: onCreate,
      child: categories.when(
        loading: () => const AmpereSkeletonList(rows: 5),
        error: (_, _) => const ScreenStateView(status: ScreenStatus.error),
        data: (items) {
          if (items.isEmpty) {
            return const ScreenStateView(
              status: ScreenStatus.empty,
              title: 'Aucune catégorie',
              message:
                  'Organisez le catalogue : câbles, éclairage, protection…',
            );
          }
          final roots = items.where((c) => c.parentId == null);
          return ListView(
            padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
            children: [
              for (final root in roots) ...[
                _Row(
                  icon: LucideIcons.folder,
                  title: root.name,
                  isActive: root.isActive,
                  onTap: () => onEdit(root),
                  trailing: IconButton(
                    tooltip: 'Ajouter une sous-catégorie',
                    icon: const Icon(LucideIcons.folderPlus, size: 18),
                    onPressed: () => onAddChild(root),
                  ),
                ),
                for (final child in items.where((c) => c.parentId == root.id))
                  Padding(
                    padding: const EdgeInsets.only(left: 28),
                    child: _Row(
                      icon: LucideIcons.cornerDownRight,
                      title: child.name,
                      isActive: child.isActive,
                      onTap: () => onEdit(child),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Emplacements du dépôt (ADMIN + MAGASINIER), triés par code.
class LocationsList extends ConsumerWidget {
  const LocationsList({
    super.key,
    required this.margin,
    required this.onCreate,
    required this.onEdit,
  });

  final double margin;
  final VoidCallback onCreate;
  final void Function(StorageLocation location) onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locations = ref.watch(locationsProvider);
    return _Section(
      margin: margin,
      createLabel: 'Nouvel emplacement',
      onCreate: onCreate,
      child: locations.when(
        loading: () => const AmpereSkeletonList(rows: 5),
        error: (_, _) => const ScreenStateView(status: ScreenStatus.error),
        data: (items) {
          final bins = [
            for (final l in items)
              if (l.isBin) l,
          ];
          if (bins.isEmpty) {
            return const ScreenStateView(
              status: ScreenStatus.empty,
              title: 'Aucun emplacement',
              message: 'Décrivez le dépôt : Zone → Rayon → Étagère → Position.',
            );
          }
          return ListView(
            padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
            children: [
              for (final bin in bins)
                _Row(
                  icon: LucideIcons.mapPin,
                  title: bin.code,
                  mono: true,
                  subtitle: bin.name,
                  isActive: bin.isActive,
                  onTap: () => onEdit(bin),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.margin,
    required this.createLabel,
    required this.onCreate,
    required this.child,
  });

  final double margin;
  final String createLabel;
  final VoidCallback onCreate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(LucideIcons.plus, size: 17),
              label: Text(createLabel),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.isActive,
    required this.onTap,
    this.subtitle,
    this.mono = false,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool mono;
  final bool isActive;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AmpereTappable(
        onTap: onTap,
        borderRadius: AmpereGeometry.cardRadiusMobile,
        color: colors.surface,
        child: Container(
          constraints: const BoxConstraints(
            minHeight: AmpereGeometry.listRowMin,
          ),
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          decoration: BoxDecoration(
            border: Border.all(
              color: colors.line,
              width: AmpereGeometry.borderWidth,
            ),
            borderRadius: BorderRadius.circular(
              AmpereGeometry.cardRadiusMobile,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: colors.ink3),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono
                          ? AmpereType.mono.copyWith(
                              color: colors.ink,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            )
                          : AmpereType.rowTitle.copyWith(color: colors.ink),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AmpereType.meta.copyWith(color: colors.ink3),
                      ),
                  ],
                ),
              ),
              if (!isActive) ...[
                const SizedBox(width: 8),
                const AmpereBadge(label: 'Inactif', tone: StatusTone.warn),
              ],
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
