import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/export_button.dart';
import '../../../ui/navigation.dart';
import '../../../ui/widgets/page_kit.dart';
import '../../../ui/widgets/pill_tabs.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/stock_controller.dart';
import '../data/stock_api.dart';
import '../data/stock_models.dart';
import '../../scan/presentation/scan_screen.dart';
import 'loss_form.dart';
import 'stock_status.dart';
import '../../catalog/presentation/requested_search.dart';

/// Droits du stock, MIROIRS des guards serveur (`docs/permissions.md`).
class StockRights {
  StockRights(AuthUser user)
    : canDeclareLoss =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('stock.loss'),
      canValidateLoss =
          user.hasRole('ADMIN') && user.can('stock.adjust.validate'),
      // `POST /stock/entries` : ADMIN|MAGASINIER + stock.adjust.
      canAddStock =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('stock.adjust');

  final bool canDeclareLoss;
  final bool canAddStock;
  final bool canValidateLoss;
}

enum _Section { levels, losses }

/// Filtre des niveaux, porté par les tuiles colorées.
enum _Filter { all, out, low, ok }

_Filter _filterOf(StockState state) => switch (state) {
  StockState.out => _Filter.out,
  StockState.low => _Filter.low,
  StockState.inStock => _Filter.ok,
};

/// Stock : niveaux par produit (magasin · dépôt · transit · total · disponible)
/// et pertes / casse. Lu EN LIGNE — un stock périmé affiché comme vrai
/// tromperait une vente (docs/context.md).
///
/// Refonte du 2026-10-13 (MEDMEDBEN) : chiffres clés colorés qui filtrent, les
/// actions du stock en boutons expliqués, et un guide quand tout est vide.
class StockScreen extends ConsumerStatefulWidget {
  const StockScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends ConsumerState<StockScreen> {
  _Section _section = _Section.levels;

  @override
  Widget build(BuildContext context) {
    final rights = StockRights(widget.user);
    final isDesktop = isDesktopWidth(MediaQuery.sizeOf(context).width);
    final margin = isDesktop
        ? AmpereGeometry.screenMarginDesktop
        : AmpereGeometry.screenMarginMobile;
    final pending = rights.canDeclareLoss
        ? ref.watch(stockLossesProvider(StockLossStatus.pending)).value?.length
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rights.canDeclareLoss)
          Padding(
            padding: EdgeInsets.fromLTRB(margin, 14, margin, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: PillTabs<_Section>(
                items: [
                  (_Section.levels, LucideIcons.layers, 'Niveaux'),
                  (
                    _Section.losses,
                    LucideIcons.triangleAlert,
                    pending == null || pending == 0
                        ? 'Pertes'
                        : 'Pertes · $pending',
                  ),
                ],
                selected: _section,
                onSelect: (s) => setState(() => _section = s),
              ),
            ),
          ),
        Expanded(
          child: _section == _Section.losses && rights.canDeclareLoss
              ? _LossesSection(margin: margin, rights: rights)
              : _LevelsSection(
                  margin: margin,
                  isDesktop: isDesktop,
                  user: widget.user,
                  rights: rights,
                ),
        ),
      ],
    );
  }
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

ScreenStateView _errorView(Object error, VoidCallback retry) => ScreenStateView(
  status: error is ApiException && error.isOffline
      ? ScreenStatus.offline
      : ScreenStatus.error,
  message: error is ApiException ? error.userMessage : null,
  onRetry: retry,
);

/// Identifiants du magasin, du dépôt et du transit (emplacements uniques).
Map<String, String> _stockLocationIds(List<StorageLocation> locations) => {
  for (final l in locations)
    if (!l.isBin) l.type: l.id,
};

/// Entrée de stock sans achat (depuis l'écran ou la fiche d'un produit).
Future<void> _addStock(BuildContext context, [Product? product]) async {
  final movement = await openFormPanel<StockMovementEntry>(
    context,
    LossForm.entry(product: product),
  );
  if (movement == null || !context.mounted) return;
  _snack(
    context,
    'Stock ajouté : +${formatQuantity(movement.quantity)}, à votre nom.',
  );
}

/// Déclaration d'une perte (depuis l'écran ou la fiche d'un produit).
Future<void> _declareLoss(
  BuildContext context,
  StockRights rights, [
  Product? product,
]) async {
  final loss = await openFormPanel<StockLoss>(
    context,
    LossForm(appliesImmediately: rights.canValidateLoss, product: product),
  );
  if (loss == null || !context.mounted) return;
  _snack(
    context,
    loss.status == StockLossStatus.pending
        ? 'Perte envoyée à l’administrateur pour validation.'
        : 'Perte enregistrée, stock mis à jour.',
  );
}

class _LevelsSection extends ConsumerStatefulWidget {
  const _LevelsSection({
    required this.margin,
    required this.isDesktop,
    required this.user,
    required this.rights,
  });

  final double margin;
  final bool isDesktop;
  final AuthUser user;
  final StockRights rights;

  @override
  ConsumerState<_LevelsSection> createState() => _LevelsSectionState();
}

class _LevelsSectionState extends ConsumerState<_LevelsSection>
    with FollowsRequestedSearch {
  final _search = SearchField();
  _Filter _filter = _Filter.all;

  @override
  TextEditingController get searchField => _search;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Les actions du stock, chacune vers l'écran qui la fait — seulement
  /// celles que le menu de ce compte propose (mêmes droits).
  List<Widget> _actions(Set<String> menu) => [
    if (widget.rights.canAddStock)
      ActionTile(
        icon: LucideIcons.packagePlus,
        title: 'Ajouter du stock',
        subtitle: 'Stock déjà là, sans achat : à votre nom, avec un motif.',
        tone: StatusTone.ok,
        prominent: true,
        onTap: () => _addStock(context),
      ),
    if (widget.rights.canDeclareLoss)
      ActionTile(
        icon: LucideIcons.triangleAlert,
        title: 'Déclarer une perte',
        subtitle: 'Casse, vol, produit abîmé : le stock sera corrigé.',
        tone: StatusTone.error,
        onTap: () => _declareLoss(context, widget.rights),
      ),
    if (menu.contains('Inventaire'))
      ActionTile(
        icon: LucideIcons.clipboardCheck,
        title: 'Compter le stock',
        subtitle: 'Inventaire : comparer le réel au théorique.',
        tone: StatusTone.info,
        onTap: () => goToDestination(ref, 'Inventaire'),
      ),
    if (menu.contains('Transferts'))
      ActionTile(
        icon: LucideIcons.arrowLeftRight,
        title: 'Transférer',
        subtitle: 'Déplacer de la marchandise entre dépôt et magasin.',
        tone: StatusTone.neutral,
        onTap: () => goToDestination(ref, 'Transferts'),
      ),
    if (menu.contains('Réappro'))
      ActionTile(
        icon: LucideIcons.shoppingBasket,
        title: 'À racheter',
        subtitle: 'Produits sous le seuil minimum, prêts à commander.',
        tone: StatusTone.warn,
        onTap: () => goToDestination(ref, 'Réappro'),
      ),
    if (menu.contains('Achats'))
      ActionTile(
        icon: LucideIcons.truck,
        title: 'Réceptionner',
        subtitle: 'Entrer en stock une livraison fournisseur.',
        tone: StatusTone.ok,
        onTap: () => goToDestination(ref, 'Achats'),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    followRequestedSearch();
    final colors = AmpereColors.of(context);
    final stock = ref.watch(stockByProductProvider);
    final products = ref.watch(productsProvider).value ?? const <Product>[];
    final locations = ref.watch(locationsProvider).value ?? const [];
    final ids = _stockLocationIds(locations);
    final search = ref.watch(productFilterProvider).search;
    final menu = {for (final d in destinationsFor(widget.user)) d.label};

    final searchBar = Row(
      children: [
        Expanded(
          child: TextField(
            controller: _search,
            autocorrect: false,
            style: AmpereType.input.copyWith(color: colors.ink),
            decoration: InputDecoration(
              hintText: 'Chercher un produit : nom, référence, code-barres',
              prefixIcon: const Icon(LucideIcons.search, size: 17),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CameraScanButton(
                    onCode: (code) {
                      _search.text = code;
                      ref.read(productFilterProvider.notifier).setSearch(code);
                    },
                  ),
                  IconButton(
                    tooltip: 'Actualiser le stock',
                    icon: const Icon(LucideIcons.refreshCw, size: 17),
                    onPressed: () => ref.invalidate(stockByProductProvider),
                  ),
                ],
              ),
            ),
            onChanged: ref.read(productFilterProvider.notifier).setSearch,
          ),
        ),
        const SizedBox(width: 8),
        ExportButton(
          targets: [
            ExportTarget('Stock', ref.read(stockApiProvider).exportLevels),
            ExportTarget(
              'Mouvements (30 jours)',
              ref.read(stockApiProvider).exportMovements,
            ),
          ],
        ),
      ],
    );

    return stock.when(
      loading: () => const AmpereSkeletonList(rows: 6),
      error: (error, _) =>
          _errorView(error, () => ref.invalidate(stockByProductProvider)),
      data: (byProduct) {
        StockState stateOf(Product p) => stockStateOf(
          (byProduct[p.id] ?? const ProductStock([])).total,
          p.minThreshold,
        );
        final counts = {for (final f in _Filter.values) f: 0};
        for (final p in products) {
          final f = _filterOf(stateOf(p));
          counts[f] = counts[f]! + 1;
        }
        counts[_Filter.all] = products.length;
        final shown = [
          for (final p in products)
            if (_filter == _Filter.all || _filterOf(stateOf(p)) == _filter) p,
        ];
        // Ce qui manque en premier : rupture, puis faible, puis le reste.
        shown.sort((a, b) => stateOf(b).index.compareTo(stateOf(a).index));

        StatTile tile(
          _Filter f,
          IconData icon,
          String label,
          StatusTone tone,
        ) => StatTile(
          icon: icon,
          label: label,
          value: '${counts[f]}',
          tone: tone,
          selected: _filter == f,
          onTap: () => setState(() => _filter = _filter == f ? _Filter.all : f),
        );

        final catalogEmpty = products.isEmpty && search.isEmpty;
        final actions = _actions(menu);
        return ListView(
          padding: withNavBar(
            context,
            EdgeInsets.fromLTRB(widget.margin, 14, widget.margin, 24),
          ),
          children: [
            if (catalogEmpty) ...[
              const GuideSteps(
                title: 'POUR AVOIR DU STOCK ICI',
                current: 0,
                steps: [
                  (
                    'Créer les produits',
                    'Dans Catalogue : nom, unité, prix, seuil minimum.',
                  ),
                  (
                    'Les faire entrer',
                    'Une réception fournisseur (Achats) ou un premier '
                        'inventaire compte ce qui est déjà en rayon.',
                  ),
                  (
                    'Suivre ici',
                    'Magasin, dépôt, transit : chaque produit, en couleur '
                        'selon son état.',
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (actions.isNotEmpty) ...[
              ActionGrid(children: actions),
              const SizedBox(height: 14),
            ],
            if (!catalogEmpty) ...[
              searchBar,
              const SizedBox(height: 10),
              // Filtres SOUS la recherche (demande MEDMEDBEN du 2026-10-26) :
              // on agit en haut, on trie la liste juste au-dessus d'elle.
              StatGrid(
                children: [
                  tile(
                    _Filter.all,
                    LucideIcons.package,
                    'Produits suivis',
                    StatusTone.info,
                  ),
                  tile(
                    _Filter.out,
                    LucideIcons.circleX,
                    'En rupture',
                    StatusTone.error,
                  ),
                  tile(
                    _Filter.low,
                    LucideIcons.triangleAlert,
                    'Stock faible',
                    StatusTone.warn,
                  ),
                  tile(
                    _Filter.ok,
                    LucideIcons.circleCheck,
                    'En stock',
                    StatusTone.ok,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_filter != _Filter.all)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${shown.length} produit(s) · ${switch (_filter) {
                            _Filter.out => 'en rupture',
                            _Filter.low => 'sous le seuil minimum',
                            _Filter.ok => 'en stock',
                            _Filter.all => '',
                          }}',
                          style: AmpereType.meta.copyWith(color: colors.ink2),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => setState(() => _filter = _Filter.all),
                        icon: const Icon(LucideIcons.x, size: 15),
                        label: const Text('Tout afficher'),
                      ),
                    ],
                  ),
                ),
              if (shown.isEmpty)
                search.isNotEmpty
                    ? ScreenStateView(
                        status: ScreenStatus.noResults,
                        searchTerm: search,
                      )
                    : ScreenStateView(
                        status: ScreenStatus.empty,
                        title: switch (_filter) {
                          _Filter.out => 'Aucune rupture',
                          _Filter.low => 'Aucun produit sous son seuil',
                          _ => 'Aucun produit',
                        },
                        message: 'Rien à traiter de ce côté : tout va bien.',
                      )
              else
                for (final p in shown)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _LevelRow(
                      product: p,
                      stock: byProduct[p.id] ?? const ProductStock([]),
                      locationIds: ids,
                      isDesktop: widget.isDesktop,
                      onTap: () => openFormPanel<void>(
                        context,
                        _ProductStockPanel(
                          product: p,
                          onDeclareLoss: widget.rights.canDeclareLoss
                              ? () => _declareLoss(context, widget.rights, p)
                              : null,
                          onAddStock: widget.rights.canAddStock
                              ? () => _addStock(context, p)
                              : null,
                        ),
                      ),
                    ),
                  ),
            ],
          ],
        );
      },
    );
  }
}

class _LevelRow extends StatelessWidget {
  const _LevelRow({
    required this.product,
    required this.stock,
    required this.locationIds,
    required this.isDesktop,
    required this.onTap,
  });

  final Product product;
  final ProductStock stock;
  final Map<String, String> locationIds;
  final bool isDesktop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final unit = product.unit.short;
    final alert = switch (stockStateOf(stock.total, product.minThreshold)) {
      StockState.out => colors.error,
      StockState.low => colors.warn,
      StockState.inStock => null,
    };

    String at(String type) => locationIds[type] == null
        ? '0'
        : formatQuantity(stock.at(locationIds[type]!));

    final figures = [
      ('Magasin', at('MAGASIN')),
      ('Dépôt', at('DEPOT')),
      ('Transit', at('TRANSIT')),
      ('Total', formatQuantity(stock.total)),
      ('Disponible', formatQuantity(stock.available)),
    ];

    return AmpereTappable(
      onTap: onTap,
      borderRadius: AmpereGeometry.cardRadiusMobile,
      color: colors.surface,
      child: Container(
        constraints: const BoxConstraints(minHeight: AmpereGeometry.listRowMin),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: alert?.withValues(alpha: 0.55) ?? colors.line,
            width: alert == null ? AmpereGeometry.borderWidth : 1.4,
          ),
          borderRadius: BorderRadius.circular(AmpereGeometry.cardRadiusMobile),
        ),
        child: Flex(
          direction: isDesktop ? Axis.horizontal : Axis.vertical,
          crossAxisAlignment: isDesktop
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.stretch,
          children: [
            Flexible(
              flex: isDesktop ? 3 : 0,
              fit: FlexFit.tight,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          product.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AmpereType.rowTitle.copyWith(
                            color: colors.ink,
                          ),
                        ),
                        Text(
                          product.sku,
                          style: AmpereType.mono.copyWith(color: colors.ink3),
                        ),
                      ],
                    ),
                  ),
                  StockStatusBadge(product: product, stock: stock),
                ],
              ),
            ),
            SizedBox(width: isDesktop ? 16 : 0, height: isDesktop ? 0 : 8),
            Flexible(
              flex: isDesktop ? 4 : 0,
              fit: FlexFit.tight,
              child: Row(
                children: [
                  for (final (label, value) in figures)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            // Téléphone : « DISPO. » tient sur une ligne.
                            (!isDesktop && label == 'Disponible'
                                    ? 'Dispo.'
                                    : label)
                                .toUpperCase(),
                            maxLines: 1,
                            style: AmpereType.label.copyWith(
                              color: colors.ink3,
                            ),
                          ),
                          Text(
                            '$value $unit',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AmpereType.bodyStrong.copyWith(
                              color: label == 'Disponible'
                                  ? colors.ink
                                  : colors.ink2,
                              fontFeatures: AmpereType.tabular,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fiche de stock d'un produit : niveaux par emplacement + journal récent.
class _ProductStockPanel extends ConsumerWidget {
  const _ProductStockPanel({
    required this.product,
    this.onDeclareLoss,
    this.onAddStock,
  });

  final Product product;

  /// `null` : ce compte n'ajoute pas de stock à la main.
  final VoidCallback? onAddStock;

  /// `null` : ce compte ne déclare pas de perte.
  final VoidCallback? onDeclareLoss;

  static const _movementLabels = {
    'RECEPTION': 'Réception',
    'VENTE': 'Vente',
    'RETOUR_CLIENT': 'Retour client',
    'RETOUR_FOURNISSEUR': 'Retour fournisseur',
    'TRANSFERT_SORTIE': 'Transfert (sortie)',
    'TRANSFERT_ENTREE': 'Transfert (entrée)',
    'AJUSTEMENT_INVENTAIRE': 'Ajustement d’inventaire',
    'PERTE_CASSE': 'Perte / casse',
    'ENTREE_MANUELLE': 'Entrée manuelle',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final stock = ref.watch(stockByProductProvider).value?[product.id];
    final movements = ref.watch(productMovementsProvider(product.id));
    final locationNames = {
      for (final l in ref.watch(locationsProvider).value ?? const [])
        l.id: l.name,
    };
    final unit = product.unit.short;

    return FormPanelFrame(
      formKey: GlobalKey<FormState>(),
      title: product.name,
      children: [
        Row(
          children: [
            if (stock != null) StockStatusBadge(product: product, stock: stock),
            const Spacer(),
            Text(
              product.minThreshold > Quantity.zero
                  ? 'Seuil minimum : ${formatQuantity(product.minThreshold)} $unit'
                  : 'Pas de seuil minimum',
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
          ],
        ),
        if (onAddStock != null) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: colors.ok,
              foregroundColor: colors.bg,
            ),
            onPressed: () {
              Navigator.of(context).pop();
              onAddStock!();
            },
            icon: const Icon(LucideIcons.packagePlus, size: 16),
            label: const Text('Ajouter du stock'),
          ),
        ],
        if (onDeclareLoss != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.error,
              side: BorderSide(color: colors.error.withValues(alpha: 0.6)),
            ),
            onPressed: () {
              Navigator.of(context).pop();
              onDeclareLoss!();
            },
            icon: const Icon(LucideIcons.triangleAlert, size: 16),
            label: const Text('Déclarer une perte sur ce produit'),
          ),
        ],
        const SizedBox(height: 16),
        const AmpereFieldLabel('Par emplacement'),
        if (stock == null || stock.levels.isEmpty)
          Text(
            'Aucun stock enregistré pour ce produit.',
            style: AmpereType.body.copyWith(color: colors.ink3),
          )
        else
          for (final level in stock.levels)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      locationNames[level.locationId] ?? 'Emplacement',
                      style: AmpereType.body.copyWith(color: colors.ink),
                    ),
                  ),
                  Text(
                    '${formatQuantity(level.quantity)} $unit'
                    '${level.reservedQuantity > Quantity.zero ? ' · ${formatQuantity(level.reservedQuantity)} réservé' : ''}',
                    style: AmpereType.bodyStrong.copyWith(
                      color: colors.ink,
                      fontFeatures: AmpereType.tabular,
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 20),
        const AmpereFieldLabel('Derniers mouvements'),
        movements.when(
          loading: () =>
              const SizedBox(height: 120, child: AmpereSkeletonList(rows: 3)),
          error: (error, _) => AmpereInlineAlert(
            message: error is ApiException
                ? error.userMessage
                : 'Journal indisponible',
          ),
          data: (entries) => entries.isEmpty
              ? Text(
                  'Aucun mouvement.',
                  style: AmpereType.body.copyWith(color: colors.ink3),
                )
              : Column(
                  children: [
                    for (final m in entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _movementLabels[m.type] ?? m.type,
                                    style: AmpereType.body.copyWith(
                                      color: colors.ink,
                                    ),
                                  ),
                                  if (m.comment != null)
                                    Text(
                                      m.comment!,
                                      style: AmpereType.meta.copyWith(
                                        color: colors.ink2,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  Text(
                                    '${formatDateTime(m.createdAt)} · '
                                    '${locationNames[m.locationId] ?? ''}'
                                    '${m.userName == null ? '' : ' · par ${m.userName}'}',
                                    style: AmpereType.meta.copyWith(
                                      color: colors.ink3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${m.quantity > Quantity.zero ? '+' : ''}'
                              '${formatQuantity(m.quantity)} $unit',
                              style: AmpereType.bodyStrong.copyWith(
                                // Entrée verte, sortie rouge.
                                color: m.quantity < Quantity.zero
                                    ? colors.error
                                    : colors.ok,
                                fontFeatures: AmpereType.tabular,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _LossesSection extends ConsumerStatefulWidget {
  const _LossesSection({required this.margin, required this.rights});

  final double margin;
  final StockRights rights;

  @override
  ConsumerState<_LossesSection> createState() => _LossesSectionState();
}

class _LossesSectionState extends ConsumerState<_LossesSection> {
  StockLossStatus? _status = StockLossStatus.pending;
  final _busy = <String>{};

  Future<void> _decide(StockLoss loss, {required bool validate}) async {
    if (!validate) {
      final confirmed = await showAmpereConfirmDialog(
        context,
        title: 'Refuser la déclaration ?',
        body: 'Le stock ne sera pas modifié. Le déclarant verra le refus.',
        confirmLabel: 'Refuser',
      );
      if (!confirmed) return;
    }
    setState(() => _busy.add(loss.id));
    try {
      final actions = ref.read(stockActionsProvider);
      validate
          ? await actions.validate(loss.id)
          : await actions.reject(loss.id);
      if (mounted) {
        _snack(
          context,
          validate
              ? 'Perte validée, stock mis à jour.'
              : 'Déclaration refusée.',
        );
      }
    } on ApiException catch (error) {
      if (mounted) _snack(context, error.userMessage);
    } finally {
      if (mounted) setState(() => _busy.remove(loss.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final losses = ref.watch(stockLossesProvider(_status));
    final products = {
      for (final p
          in ref.watch(activeProductsProvider).value ?? const <Product>[])
        p.id: p,
    };
    final locationNames = {
      for (final l in ref.watch(locationsProvider).value ?? const [])
        l.id: l.name,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(widget.margin, 14, widget.margin, 10),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final status in [StockLossStatus.pending, null])
                ChoiceChip(
                  label: Text(status == null ? 'Toutes' : status.label),
                  selected: _status == status,
                  onSelected: (_) => setState(() => _status = status),
                ),
              FilledButton.icon(
                onPressed: () => _declareLoss(context, widget.rights),
                icon: const Icon(LucideIcons.plus, size: 17),
                label: const Text('Déclarer une perte'),
              ),
            ],
          ),
        ),
        Expanded(
          child: losses.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) =>
                _errorView(error, () => ref.invalidate(stockLossesProvider)),
            data: (items) {
              if (items.isEmpty) {
                return ListView(
                  padding: withNavBar(
                    context,
                    EdgeInsets.fromLTRB(widget.margin, 0, widget.margin, 24),
                  ),
                  children: [
                    AmpereInlineAlert(
                      tone: StatusTone.ok,
                      message: _status == StockLossStatus.pending
                          ? 'Aucune perte en attente de validation.'
                          : 'Aucune perte déclarée pour l’instant.',
                    ),
                    const SizedBox(height: 12),
                    GuideSteps(
                      title: 'UNE CASSE, UN VOL, UN PRODUIT ABÎMÉ ?',
                      steps: [
                        (
                          'Déclarer',
                          '« Déclarer une perte » : produit, quantité, lieu '
                              'et ce qui s’est passé.',
                        ),
                        widget.rights.canValidateLoss
                            ? (
                                'Le stock baisse',
                                'Déclarée par l’administrateur, la perte est '
                                    'appliquée aussitôt.',
                              )
                            : (
                                'L’administrateur valide',
                                'Il reçoit la déclaration et la valide ou la '
                                    'refuse, avec un motif.',
                              ),
                        (
                          'Tracé',
                          'La perte reste dans le journal du produit '
                              '(Niveaux → fiche du produit).',
                        ),
                      ],
                    ),
                  ],
                );
              }
              return ListView.separated(
                padding: withNavBar(
                  context,
                  EdgeInsets.fromLTRB(widget.margin, 0, widget.margin, 24),
                ),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final loss = items[i];
                  final product = products[loss.productId];
                  final pending = loss.status == StockLossStatus.pending;
                  final busy = _busy.contains(loss.id);
                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      border: Border.all(color: colors.line),
                      borderRadius: BorderRadius.circular(
                        AmpereGeometry.cardRadiusMobile,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                product?.name ?? 'Produit',
                                style: AmpereType.rowTitle.copyWith(
                                  color: colors.ink,
                                ),
                              ),
                            ),
                            AmpereBadge(
                              label: loss.status.label,
                              tone: switch (loss.status) {
                                StockLossStatus.pending => StatusTone.warn,
                                StockLossStatus.validated => StatusTone.ok,
                                StockLossStatus.rejected => StatusTone.neutral,
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '−${formatQuantity(loss.quantity)} ${product?.unit.short ?? ''}'
                          ' · ${locationNames[loss.locationId] ?? ''}'
                          ' · ${formatDateTime(loss.createdAt)}',
                          style: AmpereType.meta.copyWith(color: colors.ink2),
                        ),
                        if (loss.comment != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            loss.comment!,
                            style: AmpereType.body.copyWith(color: colors.ink),
                          ),
                        ],
                        if (loss.decisionNote != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Motif : ${loss.decisionNote}',
                            style: AmpereType.meta.copyWith(color: colors.ink3),
                          ),
                        ],
                        if (pending && widget.rights.canValidateLoss) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              // Un seul bouton plein par écran (§6) : « Valider »
                              // reste en contour, la déclaration est l'action principale.
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: colors.ok,
                                  side: BorderSide(
                                    color: colors.ok.withValues(alpha: 0.6),
                                  ),
                                ),
                                onPressed: busy
                                    ? null
                                    : () => _decide(loss, validate: true),
                                icon: const Icon(LucideIcons.check, size: 16),
                                label: const Text('Valider'),
                              ),
                              AmpereDangerButton(
                                onPressed: busy
                                    ? null
                                    : () => _decide(loss, validate: false),
                                label: 'Refuser',
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
