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
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/stock_controller.dart';
import '../data/stock_models.dart';
import 'loss_form.dart';
import 'stock_status.dart';

/// Droits du stock, MIROIRS des guards serveur (`docs/permissions.md`).
class StockRights {
  StockRights(AuthUser user)
    : canDeclareLoss =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('stock.loss'),
      canValidateLoss =
          user.hasRole('ADMIN') && user.can('stock.adjust.validate');

  final bool canDeclareLoss;
  final bool canValidateLoss;
}

enum _Section { levels, losses }

/// Stock : niveaux par produit (magasin · dépôt · transit · total · disponible)
/// et pertes / casse. Lu EN LIGNE — un stock périmé affiché comme vrai
/// tromperait une vente (docs/context.md).
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rights.canDeclareLoss)
          Padding(
            padding: EdgeInsets.fromLTRB(margin, 14, margin, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<_Section>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Section.levels, label: Text('Niveaux')),
                  ButtonSegment(value: _Section.losses, label: Text('Pertes')),
                ],
                selected: {_section},
                onSelectionChanged: (s) => setState(() => _section = s.first),
              ),
            ),
          ),
        Expanded(
          child: _section == _Section.losses && rights.canDeclareLoss
              ? _LossesSection(margin: margin, rights: rights)
              : _LevelsSection(margin: margin, isDesktop: isDesktop),
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

class _LevelsSection extends ConsumerStatefulWidget {
  const _LevelsSection({required this.margin, required this.isDesktop});

  final double margin;
  final bool isDesktop;

  @override
  ConsumerState<_LevelsSection> createState() => _LevelsSectionState();
}

class _LevelsSectionState extends ConsumerState<_LevelsSection> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final stock = ref.watch(stockByProductProvider);
    final products = ref.watch(productsProvider).value ?? const <Product>[];
    final locations = ref.watch(locationsProvider).value ?? const [];
    final ids = _stockLocationIds(locations);
    final filter = ref.watch(productFilterProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(widget.margin, 14, widget.margin, 10),
          child: TextField(
            controller: _search,
            autocorrect: false,
            style: AmpereType.input.copyWith(color: colors.ink),
            decoration: InputDecoration(
              hintText: 'Nom, référence, code-barres',
              prefixIcon: const Icon(LucideIcons.search, size: 17),
              suffixIcon: IconButton(
                tooltip: 'Actualiser le stock',
                icon: const Icon(LucideIcons.refreshCw, size: 17),
                onPressed: () => ref.invalidate(stockByProductProvider),
              ),
            ),
            onChanged: ref.read(productFilterProvider.notifier).setSearch,
          ),
        ),
        Expanded(
          child: stock.when(
            loading: () => const AmpereSkeletonList(rows: 6),
            error: (error, _) =>
                _errorView(error, () => ref.invalidate(stockByProductProvider)),
            data: (byProduct) {
              if (products.isEmpty) {
                return filter.search.isEmpty
                    ? const ScreenStateView(
                        status: ScreenStatus.empty,
                        title: 'Aucun produit',
                        message: 'Le catalogue est encore vide.',
                      )
                    : ScreenStateView(
                        status: ScreenStatus.noResults,
                        searchTerm: filter.search,
                      );
              }
              return ListView.separated(
                padding: EdgeInsets.fromLTRB(
                  widget.margin,
                  0,
                  widget.margin,
                  24,
                ),
                itemCount: products.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _LevelRow(
                  product: products[i],
                  stock: byProduct[products[i].id] ?? const ProductStock([]),
                  locationIds: ids,
                  isDesktop: widget.isDesktop,
                  onTap: () => openFormPanel<void>(
                    context,
                    _ProductStockPanel(product: products[i]),
                  ),
                ),
              );
            },
          ),
        ),
      ],
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
            color: colors.line,
            width: AmpereGeometry.borderWidth,
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
                            label.toUpperCase(),
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
  const _ProductStockPanel({required this.product});

  final Product product;

  static const _movementLabels = {
    'RECEPTION': 'Réception',
    'VENTE': 'Vente',
    'RETOUR_CLIENT': 'Retour client',
    'RETOUR_FOURNISSEUR': 'Retour fournisseur',
    'TRANSFERT_SORTIE': 'Transfert (sortie)',
    'TRANSFERT_ENTREE': 'Transfert (entrée)',
    'AJUSTEMENT_INVENTAIRE': 'Ajustement d’inventaire',
    'PERTE_CASSE': 'Perte / casse',
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
                                  Text(
                                    '${formatDateTime(m.createdAt)} · '
                                    '${locationNames[m.locationId] ?? ''}',
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
                                color: m.quantity < Quantity.zero
                                    ? colors.error
                                    : colors.ink,
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

  Future<void> _declare() async {
    final loss = await openFormPanel<StockLoss>(
      context,
      LossForm(appliesImmediately: widget.rights.canValidateLoss),
    );
    if (loss == null || !mounted) return;
    _snack(
      context,
      loss.status == StockLossStatus.pending
          ? 'Perte envoyée pour validation.'
          : 'Perte enregistrée, stock mis à jour.',
    );
  }

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
                onPressed: _declare,
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
                return ScreenStateView(
                  status: ScreenStatus.empty,
                  title: _status == StockLossStatus.pending
                      ? 'Aucune perte en attente'
                      : 'Aucune perte déclarée',
                );
              }
              return ListView.separated(
                padding: EdgeInsets.fromLTRB(
                  widget.margin,
                  0,
                  widget.margin,
                  24,
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
                              OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () => _decide(loss, validate: true),
                                child: const Text('Valider'),
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
