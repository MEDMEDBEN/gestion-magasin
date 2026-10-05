import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/navigation.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../catalog/presentation/catalog_screen.dart';
import '../../catalog/presentation/product_form.dart';
import '../../scan/presentation/scan_screen.dart';
import '../application/dashboard_controller.dart';
import '../data/dashboard_models.dart';

/// Accueil (spec §21) : un RÉSUMÉ, et « ne pas surcharger ».
///
/// Ce que l'écran affiche vient entièrement du serveur : un bloc absent est un
/// bloc que ce compte n'a pas le droit de voir, et l'écran ne le remplace pas
/// par un zéro. Les raccourcis, eux, restent proposés même hors réseau — c'est
/// là qu'ils servent le plus (la vente hors ligne fonctionne).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktop = isDesktopWidth(MediaQuery.sizeOf(context).width);
    final margin = desktop ? 24.0 : 16.0;
    final summary = ref.watch(dashboardSummaryProvider);

    return ListView(
      padding: EdgeInsets.fromLTRB(margin, 16, margin, 24),
      children: [
        Text(
          'Bonjour ${user.fullName.split(' ').first}',
          style: desktop ? AmpereType.h2 : AmpereType.h3,
        ),
        const SizedBox(height: 12),
        _Shortcuts(user: user, desktop: desktop),
        const SizedBox(height: 18),
        switch (summary) {
          // Hauteur BORNÉE : le squelette est lui-même une liste défilante,
          // et deux listes imbriquées sans borne cassent la mise en page.
          AsyncLoading() => const SizedBox(
            height: 240,
            child: AmpereSkeletonList(rows: 3),
          ),
          AsyncError(:final error) => _SummaryError(error: error),
          AsyncValue(:final value?) => _Blocks(
            summary: value,
            user: user,
            desktop: desktop,
            margin: margin,
          ),
        },
      ],
    );
  }
}

/// Le résumé n'a pas pu être lu. Il manque des CHIFFRES, pas l'application :
/// les raccourcis au-dessus restent utilisables.
class _SummaryError extends ConsumerWidget {
  const _SummaryError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Copie locale : un champ public ne se promeut pas (Dart).
    final failure = error;
    final offline = failure is ApiException && failure.isOffline;
    return AmpereInlineAlert(
      tone: offline ? StatusTone.warn : StatusTone.error,
      message: offline
          ? 'Hors ligne : le résumé du jour n’est pas à jour. Les raccourcis '
                'ci-dessus fonctionnent, ce qui est saisi partira à la '
                'synchronisation.'
          : failure is ApiException
          ? failure.userMessage
          // Jamais le `toString()` d'une exception à l'écran (§8) : il ne dit
          // rien à un vendeur et laisse fuir des détails techniques.
          : 'Le résumé du jour n’a pas pu être chargé.',
      action: TextButton(
        onPressed: () => ref.invalidate(dashboardSummaryProvider),
        child: const Text('Réessayer'),
      ),
    );
  }
}

/// Actions du quotidien, dérivées des DROITS comme le menu (§6) : le scanner
/// n'apparaît que là où il y a une caméra.
class _Shortcuts extends ConsumerWidget {
  const _Shortcuts({required this.user, required this.desktop});

  final AuthUser user;
  final bool desktop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = destinationsFor(
      user,
    ).where((d) => !(desktop && d.mobileOnly)).map((d) => d.label).toSet();
    // Seulement ce qu'on COMMENCE ici (spec §21 : nouvelle vente, scanner).
    // Le reste du menu est déjà à une tape, et les chiffres ci-dessous sont
    // eux-mêmes cliquables : rejouer toute la navigation ici la surchargerait.
    const wanted = ['Vente', 'Scanner'];
    final shortcuts = [
      for (final label in wanted)
        if (available.contains(label)) label,
    ];
    // Ajout rapide d'un produit (demande MEDMEDBEN du 2026-10-05) : mêmes
    // droits que la création au catalogue (ADMIN + product.write).
    final rights = CatalogRights(user);
    final canAdd = rights.canWriteProducts;
    if (shortcuts.isEmpty && !canAdd) return const SizedBox.shrink();

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final label in shortcuts)
          if (label == 'Vente')
            FilledButton.icon(
              onPressed: () => goToDestination(ref, label),
              icon: const Icon(LucideIcons.plus, size: 17),
              label: const Text('Nouvelle vente'),
            )
          else
            // Action secondaire : une seule action PRINCIPALE par écran (§7).
            OutlinedButton.icon(
              onPressed: () => goToDestination(ref, label),
              icon: const Icon(LucideIcons.scanBarcode, size: 17),
              label: Text(label),
            ),
        if (canAdd)
          OutlinedButton.icon(
            onPressed: () => quickAddProduct(context, ref, rights),
            icon: const Icon(LucideIcons.packagePlus, size: 17),
            label: const Text('Ajout rapide produit'),
          ),
      ],
    );
  }
}

/// Ajout rapide : sur téléphone, on scanne d'abord le code-barres (un produit
/// déjà connu s'ouvre au lieu d'être recréé) ; sinon, ou si l'on préfère, la
/// fiche s'ouvre directement pour saisir le nom.
Future<void> quickAddProduct(
  BuildContext context,
  WidgetRef ref,
  CatalogRights rights,
) async {
  String? barcode;
  if (scannerSupported) {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.scanBarcode),
              title: const Text('Scanner le code-barres'),
              onTap: () => Navigator.of(context).pop('scan'),
            ),
            ListTile(
              leading: const Icon(LucideIcons.pencil),
              title: const Text('Saisir le nom'),
              onTap: () => Navigator.of(context).pop('name'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'scan') {
      barcode = await scanWithCamera(context);
      if (barcode == null || !context.mounted) return;
    }
  }
  final products = ref.read(activeProductsProvider).value ?? const [];
  final known = barcode == null
      ? null
      : products.where((p) => p.barcode == barcode).firstOrNull;
  if (known != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Déjà au catalogue : ${known.name}')),
    );
  }
  final saved = await openFormPanel<Product>(
    context,
    ProductForm(
      existing: known,
      initialBarcode: barcode,
      canEdit: rights.canWriteProducts,
      canDisable: rights.canDisableProducts,
      canReadStock: rights.canReadStock,
      canReadSuppliers: rights.canReadSuppliers,
      canSetPrices: rights.canSetPrices,
    ),
  );
  if (saved == null || saved == known || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        known == null
            ? '${saved.name} créé — code-barres ${saved.barcode}.'
            : '${saved.name} mis à jour.',
      ),
    ),
  );
}

class _Blocks extends StatelessWidget {
  const _Blocks({
    required this.summary,
    required this.user,
    required this.desktop,
    required this.margin,
  });

  final DashboardSummary summary;
  final AuthUser user;
  final bool desktop;
  final double margin;

  /// Espace entre deux cartes ; sert aussi à calculer la largeur mobile.
  static const _gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final sales = summary.sales;
    final stock = summary.stock;
    final transfers = summary.transfers;
    final purchases = summary.purchases;
    final customers = summary.customers;
    final suppliers = summary.suppliers;
    final tasks = summary.tasks;

    if (sales == null &&
        stock == null &&
        transfers == null &&
        purchases == null &&
        customers == null &&
        suppliers == null &&
        tasks == null) {
      return const ScreenStateView(
        status: ScreenStatus.empty,
        title: 'Rien à résumer',
        message:
            'Ce compte n’a accès à aucun des chiffres de l’accueil. '
            'Demandez à l’administrateur les droits qui vous manquent.',
      );
    }

    // Une carte n'est cliquable que si l'écran visé est ouvert à CE compte :
    // les droits d'un bloc et ceux de son écran ne coïncident pas toujours
    // (cumul de rôles), et un bouton mort est pire qu'un chiffre simple.
    final open = destinationsFor(user).map((d) => d.label).toSet();
    String? to(String label) => open.contains(label) ? label : null;
    final width = desktop
        ? 232.0
        : (MediaQuery.sizeOf(context).width - 2 * margin - _gap) / 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: [
            if (sales != null)
              _Metric(
                label: 'Chiffre d’affaires du jour',
                value: formatDA(sales.revenueTtc),
                hint: '${sales.count} vente(s) validée(s)',
                desktop: desktop,
                width: width,
              ),
            if (tasks != null)
              _Metric(
                label: 'Mes tâches',
                value: '${tasks.open}',
                hint: tasks.late == 0
                    ? 'Aucune en retard'
                    : '${tasks.late} en retard',
                tone: tasks.late == 0 ? StatusTone.neutral : StatusTone.error,
                destination: to('Tâches'),
                desktop: desktop,
                width: width,
              ),
            if (stock != null)
              _Metric(
                label: 'Alertes de stock',
                value: '${stock.lowCount}',
                hint: stock.outOfStockCount == 0
                    ? 'Aucune rupture'
                    : '${stock.outOfStockCount} en rupture',
                tone: stock.lowCount == 0 && stock.outOfStockCount == 0
                    ? StatusTone.ok
                    : StatusTone.warn,
                destination: to('Stock'),
                desktop: desktop,
                width: width,
              ),
            if (transfers != null)
              _Metric(
                label: 'Transferts',
                value: '${transfers.toPrepare}',
                hint: '${transfers.inTransit} en route',
                tone: transfers.toPrepare == 0
                    ? StatusTone.neutral
                    : StatusTone.info,
                destination: to('Transferts'),
                desktop: desktop,
                width: width,
              ),
            if (purchases != null)
              _Metric(
                label: 'Commandes à recevoir',
                value: '${purchases.toReceive}',
                destination: to('Achats'),
                desktop: desktop,
                width: width,
              ),
            if (customers != null)
              _Metric(
                label: 'Dettes clients',
                value: formatDA(customers.debt),
                hint: customers.overdue == 0
                    ? 'Rien en retard'
                    : '${formatDA(customers.overdue)} en retard',
                tone: customers.overdue == 0
                    ? StatusTone.neutral
                    : StatusTone.error,
                desktop: desktop,
                width: width,
              ),
            if (suppliers != null)
              _Metric(
                label: 'Dettes fournisseurs',
                value: formatDA(suppliers.debt),
                destination: to('Fournisseurs'),
                desktop: desktop,
                width: width,
              ),
          ],
        ),
        if (sales != null && sales.last7Days.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('Ventes des 7 derniers jours', style: AmpereType.sectionTitle),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: SalesWeekChart(days: sales.last7Days),
            ),
          ),
        ],
        if (stock != null && stock.low.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('À réapprovisionner', style: AmpereType.sectionTitle),
          const SizedBox(height: 8),
          for (final row in stock.low)
            Card(
              child: ListTile(
                minTileHeight: AmpereGeometry.listRowMin,
                title: Text(row.name),
                subtitle: Text(
                  'Reste ${row.quantity} · seuil ${row.minThreshold}',
                ),
                trailing: const AmpereBadge(
                  label: 'Sous le seuil',
                  tone: StatusTone.warn,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// Barres du CA TTC par jour (P1 bis n°21m) : de simples boîtes, aucune
/// bibliothèque de graphiques. Un jour négatif (retours > ventes) : barre
/// minimale en couleur d'erreur. Chaque barre porte son montant (infobulle et
/// lecteur d'écran).
class SalesWeekChart extends StatelessWidget {
  const SalesWeekChart({super.key, required this.days});

  final List<DashboardDay> days;

  static const _height = 110.0;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final top = days.fold<int>(
      0,
      (m, d) => d.revenueTtc > m ? d.revenueTtc : m,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final (i, d) in days.indexed)
          Expanded(
            child: Semantics(
              container: true,
              label: '${formatIsoDay(d.day)} : ${formatDA(d.revenueTtc)}',
              excludeSemantics: true,
              child: Tooltip(
                message: formatDA(d.revenueTtc),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        height: top <= 0 || d.revenueTtc <= 0
                            ? 2
                            : 2 + (_height - 2) * d.revenueTtc / top,
                        decoration: BoxDecoration(
                          color: d.revenueTtc < 0
                              ? colors.error
                              : i == days.length - 1
                              ? colors.accent
                              : colors.info,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(3),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        // « JJ/MM » ; un jour mal formé s'affiche tel quel.
                        formatIsoDay(d.day).split('/').take(2).join('/'),
                        style: AmpereType.meta.copyWith(color: colors.ink3),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Un chiffre et ce qu'il veut dire. Cliquable quand l'écran correspondant est
/// ouvert à ce compte — sinon simple carte (jamais un bouton qui refuse).
class _Metric extends ConsumerWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.desktop,
    required this.width,
    this.hint,
    this.tone = StatusTone.neutral,
    this.destination,
  });

  final String label;
  final String value;
  final bool desktop;

  /// Desktop : largeur fixe (grille). Mobile : deux cartes par ligne — une
  /// seule faisait défiler le résumé sur trois écrans.
  final double width;
  final String? hint;
  final StatusTone tone;
  final String? destination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final target = destination;
    final card = Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: AmpereType.label.copyWith(color: colors.ink2)),
          const SizedBox(height: 6),
          // Un montant long RÉTRÉCIT au lieu de passer à la ligne : coupé en
          // deux, un chiffre d'affaires se lit mal et déforme la grille.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, maxLines: 1, style: AmpereType.numericHero),
          ),
          if (hint case final hint?) ...[
            const SizedBox(height: 4),
            Text(
              hint,
              style: AmpereType.meta.copyWith(
                color: switch (tone) {
                  StatusTone.error => colors.error,
                  StatusTone.warn => colors.warn,
                  StatusTone.ok => colors.ok,
                  StatusTone.info => colors.info,
                  StatusTone.neutral => colors.ink3,
                },
              ),
            ),
          ],
        ],
      ),
    );

    return SizedBox(
      width: width,
      child: Card(
        child: target == null
            ? card
            : InkWell(
                onTap: () => goToDestination(ref, target),
                borderRadius: BorderRadius.circular(
                  desktop
                      ? AmpereGeometry.cardRadiusDesktop
                      : AmpereGeometry.cardRadiusMobile,
                ),
                child: card,
              ),
      ),
    );
  }
}
