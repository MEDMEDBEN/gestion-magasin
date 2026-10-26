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
import 'dashboard_charts.dart';

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

    final colors = AmpereColors.of(context);
    // Maquette du 2026-10-26 : titre à gauche, actions à droite.
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Tableau de bord',
          style: (desktop ? AmpereType.h1 : AmpereType.h3).copyWith(
            color: colors.ink,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Bonjour ${user.fullName.split(' ').first} · '
          '${formatDate(DateTime.now())}',
          style: AmpereType.bodyDesktop.copyWith(color: colors.ink3),
        ),
      ],
    );
    return ListView(
      padding: EdgeInsets.fromLTRB(margin, 20, margin, 32),
      children: [
        if (desktop)
          Row(
            children: [
              Expanded(child: title),
              _Shortcuts(user: user, desktop: desktop),
            ],
          )
        else ...[
          title,
          const SizedBox(height: 12),
          _Shortcuts(user: user, desktop: desktop),
        ],
        const SizedBox(height: 20),
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

/// Le sens d'un chiffre (demande MEDMEDBEN du 2026-10-09), DISCRET depuis
/// la maquette du 2026-10-26 : les cartes restent neutres, seule une petite
/// pastille ou une ligne de texte prend la couleur de l'état.
enum _Meaning { good, work, watch, urgent }

StatusTone _status(_Meaning meaning) => switch (meaning) {
  _Meaning.good => StatusTone.ok,
  _Meaning.work => StatusTone.info,
  _Meaning.watch => StatusTone.warn,
  _Meaning.urgent => StatusTone.error,
};

/// « 1 tâche » / « 3 tâches » : accorder plutôt que d'écrire « tâche(s) ».
String _n(int n, String one, String many) => '$n ${n > 1 ? many : one}';

/// Un point « à faire maintenant » : gravité, icône, phrase, écran où agir.
typedef _Alert = (_Meaning, IconData, String, String?);

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

  /// Espace entre deux cartes.
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
        tasks == null &&
        summary.margin == null &&
        summary.cash == null) {
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

    // Ce qui demande une action, du plus grave au moins grave.
    final alerts = <_Alert>[
      if (tasks != null && tasks.late > 0)
        (
          _Meaning.urgent,
          LucideIcons.alarmClock,
          tasks.late > 1
              ? '${tasks.late} tâches ont dépassé leur échéance'
              : '1 tâche a dépassé son échéance',
          to('Tâches'),
        ),
      if (stock != null && stock.outOfStockCount > 0)
        (
          _Meaning.urgent,
          LucideIcons.packageX,
          '${_n(stock.outOfStockCount, 'produit épuisé', 'produits épuisés')}'
              ' : plus rien à vendre',
          to('Stock'),
        ),
      if (customers != null && customers.overdue > 0)
        (
          _Meaning.urgent,
          LucideIcons.hourglass,
          'Créances échues à relancer : ${formatDA(customers.overdue)}',
          null,
        ),
      if (summary.margin?.marginHt case final m? when m < 0)
        (
          _Meaning.urgent,
          LucideIcons.trendingDown,
          'Ventes à perte aujourd’hui : vérifiez les prix',
          to('Rapports'),
        ),
      if (summary.cash case final cash? when !cash.open)
        (
          _Meaning.watch,
          LucideIcons.lock,
          'Caisse non ouverte : saisissez le fond du jour',
          to('Vente'),
        ),
      if (stock != null && stock.lowCount > 0)
        (
          _Meaning.watch,
          LucideIcons.packageMinus,
          stock.lowCount > 1
              ? '${stock.lowCount} produits sont sous leur seuil'
              : '1 produit est sous son seuil',
          to('Stock'),
        ),
      if (transfers != null && transfers.toPrepare > 0)
        (
          _Meaning.work,
          LucideIcons.arrowLeftRight,
          '${_n(transfers.toPrepare, 'demande', 'demandes')} de transfert à traiter',
          to('Transferts'),
        ),
      if (purchases != null && purchases.toReceive > 0)
        (
          _Meaning.work,
          LucideIcons.truck,
          _n(
            purchases.toReceive,
            'livraison fournisseur attendue',
            'livraisons fournisseur attendues',
          ),
          to('Achats'),
        ),
    ];

    final days = sales?.last7Days ?? const <DashboardDay>[];
    final salesCards = [
      if (sales != null)
        _Metric(
          meaning: _Meaning.good,
          icon: LucideIcons.banknote,
          label: 'Chiffre d’affaires du jour',
          value: formatDA(sales.revenueTtc),
          hint: '${sales.count} vente(s) validée(s)',
          trend: days.length >= 2
              ? (
                  today: days.last.revenueTtc,
                  before: days[days.length - 2].revenueTtc,
                )
              : null,
        ),
      // À partir de 2 ventes (avec une seule, il répète le CA) et un CA
      // positif (des retours d'anciennes ventes le fausseraient).
      if (sales != null && sales.count > 1 && sales.revenueTtc > 0)
        _Metric(
          meaning: _Meaning.good,
          icon: LucideIcons.shoppingBag,
          label: 'Panier moyen',
          // Division ENTIÈRE arrondie, en centimes (règle 4).
          value: formatDA(
            (sales.revenueTtc * 2 + sales.count) ~/ (sales.count * 2),
          ),
          hint: 'par vente aujourd’hui',
        ),
      if (summary.margin case final margin?)
        _Metric(
          meaning: (margin.marginHt ?? 0) < 0 ? _Meaning.urgent : _Meaning.good,
          icon: LucideIcons.trendingUp,
          label: 'Marge du jour',
          value: margin.marginHt == null ? '—' : formatDA(margin.marginHt!),
          hint: margin.uncostedRevenueHt > 0
              ? '${formatDA(margin.uncostedRevenueHt)} vendus sans coût connu'
              : 'prix de vente − dernier prix d’achat',
          destination: to('Rapports'),
        ),
      if (summary.cash case final cash?)
        _Metric(
          meaning: cash.open ? _Meaning.good : _Meaning.watch,
          icon: cash.open ? LucideIcons.wallet : LucideIcons.lock,
          label: 'Ma caisse',
          value: cash.open ? formatDA(cash.currentAmount) : 'Fermée',
          hint: cash.open ? 'dans le tiroir' : 'ouvrez-la avant d’encaisser',
          destination: to('Vente'),
        ),
    ];
    final workCards = [
      if (tasks != null)
        _Metric(
          meaning: tasks.late > 0 ? _Meaning.urgent : _Meaning.work,
          icon: LucideIcons.listChecks,
          label: 'Mes tâches',
          value: '${tasks.open}',
          hint: tasks.late == 0
              ? 'Aucune en retard'
              : '${tasks.late} en retard',
          destination: to('Tâches'),
        ),
      if (stock != null)
        _Metric(
          meaning: stock.outOfStockCount > 0
              ? _Meaning.urgent
              : stock.lowCount > 0
              ? _Meaning.watch
              : _Meaning.good,
          icon: LucideIcons.boxes,
          label: 'Alertes de stock',
          value: '${stock.lowCount}',
          hint: stock.outOfStockCount == 0
              ? 'Aucune rupture'
              : '${stock.outOfStockCount} en rupture',
          destination: to('Stock'),
        ),
      if (transfers != null)
        _Metric(
          meaning: _Meaning.work,
          icon: LucideIcons.arrowLeftRight,
          label: 'Transferts',
          value: '${transfers.toPrepare}',
          hint: '${transfers.inTransit} en route',
          destination: to('Transferts'),
        ),
      if (purchases != null)
        _Metric(
          meaning: _Meaning.work,
          icon: LucideIcons.truck,
          label: 'Commandes à recevoir',
          value: '${purchases.toReceive}',
          hint: 'livraisons attendues',
          destination: to('Achats'),
        ),
    ];
    final debtCards = [
      if (customers != null)
        _Metric(
          meaning: customers.overdue > 0
              ? _Meaning.urgent
              : customers.debt > 0
              ? _Meaning.watch
              : _Meaning.good,
          icon: LucideIcons.handCoins,
          label: 'Dettes clients',
          value: formatDA(customers.debt),
          hint: customers.overdue == 0
              ? 'Rien en retard'
              : '${formatDA(customers.overdue)} en retard',
          share: customers.debt > 0 ? customers.overdue / customers.debt : null,
        ),
      if (suppliers != null)
        _Metric(
          meaning: suppliers.debt > 0 ? _Meaning.watch : _Meaning.good,
          icon: LucideIcons.receipt,
          label: 'Dettes fournisseurs',
          value: formatDA(suppliers.debt),
          hint: suppliers.debt > 0
              ? 'à payer aux fournisseurs'
              : 'Tout est réglé',
          destination: to('Fournisseurs'),
        ),
    ];

    // Maquette du 2026-10-26 : une rangée de chiffres (le verdict du jour
    // en tête), trois panneaux côte à côte, la courbe, puis le tableau.
    final kpis = [
      _Verdict(alerts: alerts),
      ...salesCards,
      ...workCards,
      ...debtCards,
    ];
    final trendDays = sales == null
        ? const <DashboardDay>[]
        : (sales.last30Days.isNotEmpty ? sales.last30Days : sales.last7Days);
    final panels = [
      if (stock != null)
        ChartCard(
          title: 'État du stock',
          subtitle: 'Produits actifs',
          child: StockHealthDonut(stock: stock),
        ),
      _AttentionPanel(alerts: alerts),
      if (sales != null)
        ChartCard(
          title: 'Meilleurs produits',
          subtitle: '30 derniers jours, par chiffre d’affaires',
          child: TopProductsChart(products: sales.topProducts),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Grid(columns: desktop ? 4 : 2, children: kpis),
        const SizedBox(height: _gap),
        _Panels(desktop: desktop, children: panels),
        if (trendDays.isNotEmpty) ...[
          const SizedBox(height: _gap),
          ChartCard(
            title: 'Ventes des ${trendDays.length} derniers jours',
            subtitle:
                '${formatDA(trendDays.fold<int>(0, (s, d) => s + d.revenueTtc))} au total',
            child: RevenueTrendChart(days: trendDays),
          ),
        ],
        if (stock != null && stock.low.isNotEmpty) ...[
          const SizedBox(height: _gap),
          _LowStockTable(rows: stock.low, destination: to('Stock')),
        ],
      ],
    );
  }
}

/// Grille à colonnes égales (cartes de chiffres).
class _Grid extends StatelessWidget {
  const _Grid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final perRow = box.maxWidth < 900 ? (columns > 2 ? 2 : columns) : columns;
      final width = (box.maxWidth - _Blocks._gap * (perRow - 1)) / perRow;
      return Wrap(
        spacing: _Blocks._gap,
        runSpacing: _Blocks._gap,
        children: [for (final c in children) SizedBox(width: width, child: c)],
      );
    },
  );
}

/// Trois panneaux côte à côte au poste (comme la maquette), empilés sinon.
class _Panels extends StatelessWidget {
  const _Panels({required this.desktop, required this.children});

  final bool desktop;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (!desktop || box.maxWidth < 1000) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, c) in children.indexed) ...[
              if (i > 0) const SizedBox(height: _Blocks._gap),
              c,
            ],
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, c) in children.indexed) ...[
            if (i > 0) const SizedBox(width: _Blocks._gap),
            Expanded(child: c),
          ],
        ],
      );
    },
  );
}

/// Le jour en une phrase : première carte de la rangée (« Your target is
/// incomplete » de la maquette) — un anneau à la couleur du point le plus
/// grave, le reste neutre.
class _Verdict extends StatelessWidget {
  const _Verdict({required this.alerts});

  final List<_Alert> alerts;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final urgent = alerts.where((a) => a.$1 == _Meaning.urgent).length;
    final watch = alerts.where((a) => a.$1 == _Meaning.watch).length;
    final (meaning, icon, text) = urgent > 0
        ? (
            _Meaning.urgent,
            LucideIcons.siren,
            '${_n(urgent, 'urgence', 'urgences')} à régler aujourd’hui',
          )
        : watch > 0
        ? (
            _Meaning.watch,
            LucideIcons.eye,
            '${_n(watch, 'point', 'points')} à surveiller',
          )
        : (_Meaning.good, LucideIcons.circleCheck, 'Tout est en ordre');
    final tone = _status(meaning).foreground(colors);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Aujourd’hui',
              style: AmpereType.bodyDesktop.copyWith(color: colors.ink2),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: tone, width: 2.5),
                  ),
                  child: Icon(icon, size: 18, color: tone),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: AmpereType.h4.copyWith(color: colors.ink),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              alerts.isEmpty
                  ? 'Rien ne demande d’action.'
                  : 'Détail dans « À faire maintenant ».',
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
          ],
        ),
      ),
    );
  }
}

/// « À faire maintenant » (le panneau « Tasks » de la maquette) : chaque point
/// dans une ligne bordée, son état en pastille, cliquable vers l'écran où
/// agir.
class _AttentionPanel extends ConsumerStatefulWidget {
  const _AttentionPanel({required this.alerts});

  final List<_Alert> alerts;

  @override
  ConsumerState<_AttentionPanel> createState() => _AttentionPanelState();
}

class _AttentionPanelState extends ConsumerState<_AttentionPanel> {
  bool _all = false;

  static const _limit = 4;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final alerts = widget.alerts;
    final hidden = _all ? 0 : alerts.length - _limit;
    final shown = hidden > 0 ? alerts.take(_limit) : alerts;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'À faire maintenant',
              style: AmpereType.h4.copyWith(color: colors.ink),
            ),
            const SizedBox(height: 2),
            Text(
              'Ce qui demande un geste aujourd’hui',
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
            const SizedBox(height: 16),
            if (alerts.isEmpty)
              Text(
                'Rien à faire pour l’instant.',
                style: AmpereType.bodyDesktop.copyWith(color: colors.ink3),
              ),
            for (final (meaning, icon, text, destination) in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: colors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: colors.line),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: destination == null
                        ? null
                        : () => goToDestination(ref, destination),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Icon(icon, size: 16, color: colors.ink2),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  text,
                                  style: AmpereType.bodyStrong.copyWith(
                                    color: colors.ink,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                AmpereBadge(
                                  label: switch (meaning) {
                                    _Meaning.urgent => 'Urgent',
                                    _Meaning.watch => 'À surveiller',
                                    _Meaning.work => 'En cours',
                                    _Meaning.good => 'En ordre',
                                  },
                                  tone: _status(meaning),
                                ),
                              ],
                            ),
                          ),
                          if (destination != null)
                            Icon(
                              LucideIcons.chevronRight,
                              size: 16,
                              color: colors.ink3,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (hidden > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _all = true),
                  icon: const Icon(LucideIcons.chevronDown, size: 16),
                  label: Text(
                    'Voir ${_n(hidden, 'autre point', 'autres points')}',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// « À réapprovisionner » en tableau (le tableau « Leads » de la maquette).
class _LowStockTable extends ConsumerWidget {
  const _LowStockTable({required this.rows, required this.destination});

  final List<DashboardLowStock> rows;
  final String? destination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final target = destination;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'À réapprovisionner',
                  style: AmpereType.h4.copyWith(color: colors.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  'Produits épuisés ou sous leur seuil',
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
              ],
            ),
          ),
          for (final row in rows) ...[
            Divider(height: 1, color: colors.line),
            InkWell(
              onTap: target == null ? null : () => goToDestination(ref, target),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.name,
                            style: AmpereType.bodyStrong.copyWith(
                              color: colors.ink,
                            ),
                          ),
                          Text(
                            'Reste ${row.quantity} · seuil ${row.minThreshold}',
                            style: AmpereType.meta.copyWith(color: colors.ink3),
                          ),
                        ],
                      ),
                    ),
                    if ((double.tryParse(row.quantity) ?? 0) <= 0)
                      const AmpereBadge(label: 'Épuisé', tone: StatusTone.error)
                    else
                      const AmpereBadge(
                        label: 'Sous le seuil',
                        tone: StatusTone.warn,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Un chiffre (carte KPI de la maquette) : libellé, icône dans un carré
/// bordé, grand nombre, une ligne d'explication. Neutre : seule la ligne du
/// bas prend la couleur d'un état à surveiller ou urgent. Cliquable quand
/// l'écran correspondant est ouvert à ce compte.
class _Metric extends ConsumerWidget {
  const _Metric({
    required this.meaning,
    required this.icon,
    required this.label,
    required this.value,
    this.hint,
    this.destination,
    this.trend,
    this.share,
  });

  final _Meaning meaning;
  final IconData icon;
  final String label;
  final String value;
  final String? hint;
  final String? destination;

  /// Aujourd'hui comparé à hier.
  final ({int today, int before})? trend;

  /// Part (0..1) en retard d'un montant dû.
  final double? share;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final target = destination;
    final evolution = switch (trend) {
      (today: final t, before: final b) when b > 0 =>
        ((t - b) * 100 / b).round(),
      _ => null,
    };
    final hintColor = switch (meaning) {
      _Meaning.urgent => colors.error,
      _Meaning.watch => colors.warn,
      _ => colors.ink3,
    };
    final card = Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  style: AmpereType.bodyDesktop.copyWith(color: colors.ink2),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colors.line),
                ),
                child: Icon(icon, size: 16, color: colors.ink2),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Un montant long RÉTRÉCIT au lieu de passer à la ligne.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: AmpereType.numeric.copyWith(
                color: colors.ink,
                fontSize: 26,
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (evolution case final e?)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${e >= 0 ? '+' : ''}$e %',
                    style: TextStyle(
                      color: e >= 0 ? colors.ok : colors.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const TextSpan(text: ' par rapport à hier'),
                ],
              ),
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
          if (hint case final hint?)
            Text(hint, style: AmpereType.meta.copyWith(color: hintColor)),
          if (share case final s?) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: s.clamp(0, 1),
                minHeight: 6,
                color: colors.ink,
                backgroundColor: colors.surface2,
              ),
            ),
          ],
        ],
      ),
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: target == null
          ? card
          : InkWell(onTap: () => goToDestination(ref, target), child: card),
    );
  }
}
