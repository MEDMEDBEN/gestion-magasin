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

/// LE code couleur de l'accueil (demande MEDMEDBEN du 2026-10-09 : des
/// couleurs qui EXPLIQUENT). Le même partout, rappelé par la légende :
/// vert = l'argent rentre / tout va bien ; bleu = travail en cours ;
/// orange = à surveiller ; rouge = urgent.
enum _Meaning { good, work, watch, urgent }

Color _tone(AmpereColors colors, _Meaning meaning) => switch (meaning) {
  _Meaning.good => colors.ok,
  _Meaning.work => colors.accent,
  _Meaning.watch => colors.warn,
  _Meaning.urgent => colors.error,
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

    final width = desktop
        ? 236.0
        : (MediaQuery.sizeOf(context).width - 2 * margin - _gap) / 2;
    Widget grid(List<Widget> cards) =>
        Wrap(spacing: _gap, runSpacing: _gap, children: cards);

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
          desktop: desktop,
          width: width,
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
          desktop: desktop,
          width: width,
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
          desktop: desktop,
          width: width,
        ),
      if (summary.cash case final cash?)
        _Metric(
          meaning: cash.open ? _Meaning.good : _Meaning.watch,
          icon: cash.open ? LucideIcons.wallet : LucideIcons.lock,
          label: 'Ma caisse',
          value: cash.open ? formatDA(cash.currentAmount) : 'Fermée',
          hint: cash.open ? 'dans le tiroir' : 'ouvrez-la avant d’encaisser',
          destination: to('Vente'),
          desktop: desktop,
          width: width,
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
          desktop: desktop,
          width: width,
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
          desktop: desktop,
          width: width,
        ),
      if (transfers != null)
        _Metric(
          meaning: _Meaning.work,
          icon: LucideIcons.arrowLeftRight,
          label: 'Transferts',
          value: '${transfers.toPrepare}',
          hint: '${transfers.inTransit} en route',
          destination: to('Transferts'),
          desktop: desktop,
          width: width,
        ),
      if (purchases != null)
        _Metric(
          meaning: _Meaning.work,
          icon: LucideIcons.truck,
          label: 'Commandes à recevoir',
          value: '${purchases.toReceive}',
          hint: 'livraisons attendues',
          destination: to('Achats'),
          desktop: desktop,
          width: width,
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
          desktop: desktop,
          width: width,
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
          desktop: desktop,
          width: width,
        ),
    ];

    final figures = <Widget>[
      if (salesCards.isNotEmpty) ...[
        const _SectionTitle(
          meaning: _Meaning.good,
          title: 'Ventes du jour',
          subtitle: 'L’argent qui rentre aujourd’hui',
        ),
        grid(salesCards),
      ],
      if (workCards.isNotEmpty) ...[
        const _SectionTitle(
          meaning: _Meaning.work,
          title: 'Travail en cours',
          subtitle: 'Tâches, stock, transferts, livraisons',
        ),
        grid(workCards),
      ],
      if (debtCards.isNotEmpty) ...[
        const _SectionTitle(
          meaning: _Meaning.watch,
          title: 'Dettes',
          subtitle: 'À récupérer des clients, à payer aux fournisseurs',
        ),
        grid(debtCards),
      ],
      // Graphiques (2026-10-05) : chacun n'apparaît que si son bloc est
      // envoyé par le serveur — le tableau de bord suit donc le RÔLE.
      if (charts(sales, stock).isNotEmpty) ...[
        const SizedBox(height: 18),
        _ChartGrid(desktop: desktop, children: charts(sales, stock)),
      ],
      if (stock != null && stock.low.isNotEmpty) ...[
        const _SectionTitle(
          meaning: _Meaning.watch,
          title: 'À réapprovisionner',
          subtitle: 'Rouge : épuisé · orange : sous le seuil',
        ),
        for (final row in stock.low)
          _LowStockRow(row: row, destination: to('Stock')),
      ],
    ];
    final header = [
      _Verdict(alerts: alerts),
      const SizedBox(height: 10),
      const _Legend(),
    ];
    // Grand écran : ce qu'il faut FAIRE reste à droite, toujours sous les
    // yeux ; les chiffres défilent à gauche. Téléphone : une colonne.
    if (desktop &&
        MediaQuery.sizeOf(context).width >= 1200 &&
        alerts.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...header,
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: figures,
                ),
              ),
              const SizedBox(width: 18),
              SizedBox(
                width: 360,
                child: Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: _AttentionList(alerts: alerts, limit: null),
                ),
              ),
            ],
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...header,
        const SizedBox(height: 16),
        _AttentionList(alerts: alerts, limit: 3),
        ...figures,
      ],
    );
  }
}

/// Le jour en une phrase, dans la couleur du point le plus grave.
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
    final tone = _tone(colors, meaning);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tone.withValues(alpha: 0.45)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tone.withValues(alpha: 0.18), tone.withValues(alpha: 0.03)],
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: tone, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: AmpereType.sectionTitle.copyWith(color: colors.ink),
                ),
                Text(
                  'Résumé du ${formatDate(DateTime.now())}',
                  style: AmpereType.meta.copyWith(color: colors.ink2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// La clé de lecture des couleurs, toujours visible.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [
        for (final (meaning, label) in [
          (_Meaning.good, 'Bon / argent qui rentre'),
          (_Meaning.work, 'En cours'),
          (_Meaning.watch, 'À surveiller'),
          (_Meaning.urgent, 'Urgent'),
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: _tone(colors, meaning),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(label, style: AmpereType.meta.copyWith(color: colors.ink2)),
            ],
          ),
      ],
    );
  }
}

/// « À faire maintenant » : les points qui demandent un geste, chacun dans
/// sa couleur, cliquable vers l'écran où agir. Rien : on le dit, en vert.
class _AttentionList extends ConsumerStatefulWidget {
  const _AttentionList({required this.alerts, required this.limit});

  final List<_Alert> alerts;

  /// Nombre de points montrés d'abord (les plus graves) ; `null` : tous.
  final int? limit;

  @override
  ConsumerState<_AttentionList> createState() => _AttentionListState();
}

class _AttentionListState extends ConsumerState<_AttentionList> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final alerts = widget.alerts;
    if (alerts.isEmpty) return const SizedBox.shrink();
    final limit = widget.limit;
    final hidden = limit == null || _all ? 0 : alerts.length - limit;
    final shown = hidden > 0 ? alerts.take(limit!) : alerts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'À faire maintenant',
          style: AmpereType.sectionTitle.copyWith(color: colors.ink),
        ),
        const SizedBox(height: 8),
        for (final (meaning, icon, text, destination) in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: colors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: colors.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: destination == null
                    ? null
                    : () => goToDestination(ref, destination),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(width: 4, color: _tone(colors, meaning)),
                      const SizedBox(width: 12),
                      Icon(icon, size: 18, color: _tone(colors, meaning)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            text,
                            style: AmpereType.body.copyWith(color: colors.ink),
                          ),
                        ),
                      ),
                      if (destination != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Icon(
                            LucideIcons.chevronRight,
                            size: 18,
                            color: colors.ink3,
                          ),
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
              label: Text('Voir ${_n(hidden, 'autre point', 'autres points')}'),
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Titre d'un bloc, précédé de SA couleur : on sait ce qu'on lit.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.meaning,
    required this.title,
    required this.subtitle,
  });

  final _Meaning meaning;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 18, 0, 10),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 30,
            decoration: BoxDecoration(
              color: _tone(colors, meaning),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AmpereType.sectionTitle.copyWith(color: colors.ink),
                ),
                Text(
                  subtitle,
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Un produit à réapprovisionner : rouge s'il est épuisé, orange sinon.
class _LowStockRow extends ConsumerWidget {
  const _LowStockRow({required this.row, required this.destination});

  final DashboardLowStock row;
  final String? destination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final out = (double.tryParse(row.quantity) ?? 0) <= 0;
    final tone = out ? colors.error : colors.warn;
    final target = destination;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: target == null ? null : () => goToDestination(ref, target),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  out ? LucideIcons.packageX : LucideIcons.packageMinus,
                  color: tone,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.name,
                        style: AmpereType.rowTitle.copyWith(color: colors.ink),
                      ),
                      Text(
                        'Reste ${row.quantity} · seuil ${row.minThreshold}',
                        style: AmpereType.meta.copyWith(color: colors.ink2),
                      ),
                    ],
                  ),
                ),
                AmpereBadge(
                  label: out ? 'Épuisé' : 'Sous le seuil',
                  tone: out ? StatusTone.error : StatusTone.warn,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Graphiques autorisés à ce compte, dans l'ordre d'affichage.
List<Widget> charts(DashboardSales? sales, DashboardStock? stock) {
  final days = sales == null
      ? const <DashboardDay>[]
      : (sales.last30Days.isNotEmpty ? sales.last30Days : sales.last7Days);
  return [
    if (days.isNotEmpty)
      ChartCard(
        title: 'Ventes des ${days.length} derniers jours',
        subtitle:
            '${formatDA(days.fold<int>(0, (s, d) => s + d.revenueTtc))} au total',
        child: RevenueTrendChart(days: days),
      ),
    if (sales != null)
      ChartCard(
        title: 'Meilleurs produits',
        subtitle: '30 derniers jours, par chiffre d’affaires',
        child: TopProductsChart(products: sales.topProducts),
      ),
    if (stock != null)
      ChartCard(
        title: 'État du stock',
        subtitle: 'Produits actifs',
        child: StockHealthDonut(stock: stock),
      ),
  ];
}

/// Deux colonnes au poste, une seule sur téléphone.
class _ChartGrid extends StatelessWidget {
  const _ChartGrid({required this.desktop, required this.children});

  final bool desktop;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (!desktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in children)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: c),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (i, c) in children.indexed)
              SizedBox(
                // La courbe prend toute la largeur, les autres une moitié.
                width: i == 0 && children.length.isOdd
                    ? constraints.maxWidth
                    : width,
                child: c,
              ),
          ],
        );
      },
    );
  }
}

/// Un chiffre, ce qu'il veut dire, et SA couleur (le code de l'accueil) :
/// liseré + icône teintés, tendance vs hier, part en retard. Cliquable quand
/// l'écran correspondant est ouvert à ce compte (jamais un bouton qui refuse).
class _Metric extends ConsumerWidget {
  const _Metric({
    required this.meaning,
    required this.icon,
    required this.label,
    required this.value,
    required this.desktop,
    required this.width,
    this.hint,
    this.destination,
    this.trend,
    this.share,
  });

  final _Meaning meaning;
  final IconData icon;
  final String label;
  final String value;
  final bool desktop;

  /// Desktop : largeur fixe (grille). Mobile : deux cartes par ligne.
  final double width;
  final String? hint;
  final String? destination;

  /// Aujourd'hui comparé à hier : flèche verte en hausse, rouge en baisse.
  final ({int today, int before})? trend;

  /// Part (0..1) en retard d'un montant dû : barre rouge sur fond orange.
  final double? share;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final tone = _tone(colors, meaning);
    final target = destination;
    final evolution = switch (trend) {
      (today: final t, before: final b) when b > 0 =>
        ((t - b) * 100 / b).round(),
      _ => null,
    };
    final card = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tone.withValues(alpha: 0.13), colors.surface],
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 16, color: tone),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  style: AmpereType.label.copyWith(color: colors.ink2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Un montant long RÉTRÉCIT au lieu de passer à la ligne.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: AmpereType.numericHero.copyWith(color: colors.ink),
            ),
          ),
          if (hint case final hint?) ...[
            const SizedBox(height: 4),
            Text(
              hint,
              style: AmpereType.meta.copyWith(
                color: meaning == _Meaning.work ? colors.ink3 : tone,
              ),
            ),
          ],
          if (evolution case final e?) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  e >= 0 ? LucideIcons.trendingUp : LucideIcons.trendingDown,
                  size: 15,
                  color: e >= 0 ? colors.ok : colors.error,
                ),
                const SizedBox(width: 5),
                Text(
                  '${e >= 0 ? '+' : ''}$e % par rapport à hier',
                  style: AmpereType.meta.copyWith(
                    color: e >= 0 ? colors.ok : colors.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
          if (share case final s?) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: s.clamp(0, 1),
                minHeight: 6,
                color: colors.error,
                backgroundColor: colors.warn.withValues(alpha: 0.35),
              ),
            ),
          ],
        ],
      ),
    );

    return SizedBox(
      width: width,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tone.withValues(alpha: 0.35)),
        ),
        child: target == null
            ? card
            : InkWell(onTap: () => goToDestination(ref, target), child: card),
      ),
    );
  }
}
