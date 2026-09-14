import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../application/catalog_controller.dart';
import '../data/catalog_models.dart';
import 'catalog_lists.dart';
import 'category_form.dart';
import 'desktop/products_table.dart';
import 'location_form.dart';
import 'mobile/products_list.dart';
import 'product_form.dart';

/// Droits du catalogue, MIROIRS des guards serveur (`docs/permissions.md`).
class CatalogRights {
  CatalogRights(AuthUser user)
    : canWriteProducts = user.hasRole('ADMIN') && user.can('product.write'),
      canDisableProducts = user.hasRole('ADMIN') && user.can('product.disable'),
      canManageLocations =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('location.manage');

  final bool canWriteProducts;
  final bool canDisableProducts;
  final bool canManageLocations;
}

enum _Section { products, categories, locations }

/// Catalogue : produits (tous les rôles), catégories (ADMIN), emplacements du
/// dépôt (ADMIN + MAGASINIER). Une seule destination de navigation, découpée en
/// sections — les coquilles gardent ainsi 4 onglets au plus (AMPÈRE §7).
///
/// Lecture **cache-first** : l'écran affiche la base locale ; la mise à jour
/// depuis le serveur tourne en arrière-plan et ne bloque jamais la lecture.
class CatalogScreen extends ConsumerStatefulWidget {
  const CatalogScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends ConsumerState<CatalogScreen> {
  final _search = TextEditingController();
  _Section _section = _Section.products;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: SnackBarAction(label: 'Fermer', onPressed: () {}),
        ),
      );
  }

  Future<void> _openProduct(CatalogRights rights, [Product? product]) async {
    final saved = await openFormPanel<Product>(
      context,
      ProductForm(
        existing: product,
        canEdit: rights.canWriteProducts,
        canDisable: rights.canDisableProducts,
      ),
    );
    if (saved == null || saved == product) return;
    _showSnack(
      product == null
          ? '${saved.name} créé — code-barres ${saved.barcode}.'
          : '${saved.name} mis à jour.',
    );
  }

  Future<void> _openCategory([
    ProductCategory? category,
    String? parentId,
  ]) async {
    final saved = await openFormPanel<ProductCategory>(
      context,
      CategoryForm(existing: category, initialParentId: parentId),
    );
    if (saved != null && saved != category) {
      _showSnack('Catégorie « ${saved.name} » enregistrée.');
    }
  }

  Future<void> _openLocation([StorageLocation? location]) async {
    final saved = await openFormPanel<StorageLocation>(
      context,
      LocationForm(existing: location),
    );
    if (saved != null && saved != location) {
      _showSnack('Emplacement ${saved.code} enregistré.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final rights = CatalogRights(widget.user);
    final isDesktop = isDesktopWidth(MediaQuery.sizeOf(context).width);
    final margin = isDesktop
        ? AmpereGeometry.screenMarginDesktop
        : AmpereGeometry.screenMarginMobile;
    final sections = [
      _Section.products,
      if (rights.canWriteProducts) _Section.categories,
      if (rights.canManageLocations) _Section.locations,
    ];
    final section = sections.contains(_section) ? _section : sections.first;

    // Lance la mise à jour du catalogue dès l'ouverture, et la garde vivante.
    final sync = ref.watch(catalogSyncProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sections.length > 1)
          Padding(
            padding: EdgeInsets.fromLTRB(margin, 14, margin, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<_Section>(
                showSelectedIcon: false,
                segments: [
                  for (final s in sections)
                    ButtonSegment(
                      value: s,
                      label: Text(switch (s) {
                        _Section.products => 'Produits',
                        _Section.categories => 'Catégories',
                        _Section.locations => 'Emplacements',
                      }),
                    ),
                ],
                selected: {section},
                onSelectionChanged: (s) => setState(() => _section = s.first),
              ),
            ),
          ),
        if (sync.hasError)
          Padding(
            padding: EdgeInsets.fromLTRB(margin, 12, margin, 0),
            child: AmpereInlineAlert(
              tone: StatusTone.warn,
              icon: LucideIcons.cloudOff,
              message: _syncMessage(sync.error!),
              action: TextButton(
                onPressed: () =>
                    ref.read(catalogSyncProvider.notifier).refresh(),
                child: const Text('Réessayer'),
              ),
            ),
          ),
        Expanded(
          child: switch (section) {
            _Section.products => _ProductsSection(
              search: _search,
              margin: margin,
              isDesktop: isDesktop,
              canCreate: rights.canWriteProducts,
              syncing: sync.isLoading,
              onOpen: (p) => _openProduct(rights, p),
            ),
            _Section.categories => CategoriesList(
              margin: margin,
              onCreate: () => _openCategory(),
              onEdit: (c) => _openCategory(c),
              onAddChild: (root) => _openCategory(null, root.id),
            ),
            _Section.locations => LocationsList(
              margin: margin,
              onCreate: () => _openLocation(),
              onEdit: _openLocation,
            ),
          },
        ),
      ],
    );
  }

  static String _syncMessage(Object error) {
    final detail = error is ApiException && !error.isOffline
        ? error.userMessage
        : 'serveur injoignable';
    return 'Catalogue non mis à jour ($detail) — la dernière version '
        'enregistrée sur ce poste reste affichée.';
  }
}

class _ProductsSection extends ConsumerWidget {
  const _ProductsSection({
    required this.search,
    required this.margin,
    required this.isDesktop,
    required this.canCreate,
    required this.syncing,
    required this.onOpen,
  });

  final TextEditingController search;
  final double margin;
  final bool isDesktop;
  final bool canCreate;
  final bool syncing;
  final void Function(Product? product) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final filter = ref.watch(productFilterProvider);
    final products = ref.watch(productsProvider);
    final categories = ref.watch(categoriesProvider).value ?? const [];
    final notifier = ref.read(productFilterProvider.notifier);
    final categoryNames = {for (final c in categories) c.id: c.name};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: search,
                  autocorrect: false,
                  style: (isDesktop ? AmpereType.bodyDesktop : AmpereType.input)
                      .copyWith(color: colors.ink),
                  decoration: InputDecoration(
                    // Une douchette USB tape le code puis « Entrée » : la
                    // recherche la reçoit comme une saisie clavier.
                    hintText: isDesktop
                        ? 'Rechercher un nom, une référence, une marque, un code-barres'
                        : 'Nom, référence, code-barres',
                    prefixIcon: const Icon(LucideIcons.search, size: 17),
                    suffixIcon: filter.search.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Effacer',
                            icon: const Icon(LucideIcons.x, size: 17),
                            onPressed: () {
                              search.clear();
                              notifier.setSearch('');
                            },
                          ),
                  ),
                  onChanged: notifier.setSearch,
                ),
              ),
              if (canCreate) ...[
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: () => onOpen(null),
                  icon: const Icon(LucideIcons.plus, size: 17),
                  label: Text(isDesktop ? 'Nouveau produit' : 'Nouveau'),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 0, margin, 10),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _CategoryFilter(
                categories: categories,
                selectedId: filter.categoryId,
                onSelected: notifier.setCategory,
              ),
              FilterChip(
                label: const Text('Inclure les inactifs'),
                selected: filter.includeInactive,
                onSelected: notifier.setIncludeInactive,
              ),
            ],
          ),
        ),
        Expanded(
          child: products.when(
            loading: () => const AmpereSkeletonList(rows: 6),
            error: (error, _) => ScreenStateView(
              status: ScreenStatus.error,
              message: 'Lecture du catalogue local impossible.',
              onRetry: () => ref.invalidate(productsProvider),
            ),
            data: (items) {
              if (items.isEmpty) {
                final filtered =
                    filter.search.isNotEmpty || filter.categoryId != null;
                if (filtered) {
                  return ScreenStateView(
                    status: ScreenStatus.noResults,
                    searchTerm: filter.search.isEmpty ? null : filter.search,
                  );
                }
                // Premier chargement encore en cours : squelette, pas « vide ».
                if (syncing) return const AmpereSkeletonList(rows: 6);
                return ScreenStateView(
                  status: ScreenStatus.empty,
                  title: 'Aucun produit',
                  message: canCreate
                      ? 'Créez le premier produit du catalogue.'
                      : 'Le catalogue est encore vide.',
                );
              }
              return isDesktop
                  ? ProductsTable(
                      products: items,
                      categoryNames: categoryNames,
                      onTap: onOpen,
                    )
                  : ProductsList(
                      products: items,
                      categoryNames: categoryNames,
                      onTap: onOpen,
                      onRefresh: () =>
                          ref.read(catalogSyncProvider.notifier).refresh(),
                    );
            },
          ),
        ),
      ],
    );
  }
}

class _CategoryFilter extends StatelessWidget {
  const _CategoryFilter({
    required this.categories,
    required this.selectedId,
    required this.onSelected,
  });

  final List<ProductCategory> categories;
  final String? selectedId;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final selected = categories.where((c) => c.id == selectedId).firstOrNull;
    // Flutter traite un choix `null` comme une fermeture du menu : « Toutes »
    // passe par une valeur sentinelle, convertie en « aucun filtre ».
    const all = '';
    return PopupMenuButton<String>(
      tooltip: 'Filtrer par catégorie',
      onSelected: (id) => onSelected(id == all ? null : id),
      itemBuilder: (_) => [
        const PopupMenuItem(value: all, child: Text('Toutes les catégories')),
        for (final root in categories.where((c) => c.parentId == null)) ...[
          PopupMenuItem(value: root.id, child: Text(root.name)),
          for (final child in categories.where((c) => c.parentId == root.id))
            PopupMenuItem(value: child.id, child: Text('    ${child.name}')),
        ],
      ],
      child: Chip(
        avatar: const Icon(LucideIcons.folderTree, size: 15),
        label: Text(selected?.name ?? 'Toutes les catégories'),
      ),
    );
  }
}
