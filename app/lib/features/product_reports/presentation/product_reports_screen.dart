import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/data/catalog_models.dart' show productUnitShort;
import '../application/product_reports_controller.dart';
import '../data/product_report_models.dart';

/// Produits dormants et produits demandés (spec §20).
///
/// Deux questions opposées dans un seul écran, et c'est voulu : « qu'est-ce qui
/// ne part pas ? » et « qu'est-ce qu'on me réclame ? ». Les regarder ensemble est
/// ce qui fait décider — pousser l'un, racheter l'autre.
class ProductReportsScreen extends StatelessWidget {
  const ProductReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Ne part plus'),
              Tab(text: 'On me réclame'),
            ],
          ),
          const Expanded(
            child: TabBarView(children: [_DormantTab(), _DemandTab()]),
          ),
        ],
      ),
    );
  }
}

/// Choix du nombre de jours. Les valeurs sont dans les bornes du serveur
/// (7 à 730) : un bouton qui ferait un 400 serait un piège.
class _DaysChips extends StatelessWidget {
  const _DaysChips({
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  final int value;
  final List<int> choices;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final days in choices)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text('$days j'),
              selected: value == days,
              onSelected: (on) {
                if (on) onChanged(days);
              },
            ),
          ),
      ],
    );
  }
}

class _DormantTab extends ConsumerWidget {
  const _DormantTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final days = ref.watch(dormantDaysProvider);
    final page = ref.watch(dormantProductsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 12, margin, 8),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: _DaysChips(
                    value: days,
                    choices: const [30, 60, 120, 365],
                    onChanged: (value) =>
                        ref.read(dormantDaysProvider.notifier).set(value),
                  ),
                ),
              ),
              if (page.value?.totalSleepingValueHt case final total?)
                Text(
                  '${formatDA(total)} immobilisés',
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
            ],
          ),
        ),
        Expanded(
          child: page.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException
                  ? error.userMessage
                  : 'Le rapport n’a pas pu être chargé.',
              onRetry: () => ref.invalidate(dormantProductsProvider),
            ),
            data: (data) => data.data.isEmpty
                ? ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Rien ne dort',
                    message:
                        // Le seuil vient de la RÉPONSE, pas du provider : c'est
                        // celui que le serveur a réellement appliqué.
                        'Aucun produit en stock n’est resté ${data.days} jours '
                        'sans être vendu. Une réception ne remet pas ce '
                        'compteur à zéro : c’est la dernière VENTE qui compte.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final row in data.data)
                        _DormantTile(key: ValueKey(row.productId), row: row),
                      // Une liste tronquée doit le DIRE : sinon on décide sur une
                      // photo partielle en croyant tout voir.
                      if (data.meta.total > data.data.length)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '${data.data.length} sur ${data.meta.total} — '
                            'les plus coûteux d’abord.',
                            style: AmpereType.meta.copyWith(color: colors.ink3),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _DormantTile extends StatelessWidget {
  const _DormantTile({super.key, required this.row});

  final DormantProduct row;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final value = row.sleepingValueHt;

    return Card(
      child: ListTile(
        minTileHeight: AmpereGeometry.listRowMin,
        title: Text(row.name, style: AmpereType.rowTitle),
        subtitle: Text(
          [
            row.sku,
            '${formatQuantity(quantityFromJson(row.quantity))} '
                '${productUnitShort(row.unit)} en stock',
            row.lastSoldAt == null
                ? 'jamais vendu'
                : 'dernière vente ${formatDate(row.lastSoldAt!)}',
            // Montré SEULEMENT quand il diffère : « reçu hier, dernière vente en
            // mars » est exactement ce qui explique la présence du produit ici,
            // et sans ça on croit l'écran en retard.
            if (row.lastMovementAt case final moved?)
              if (row.lastSoldAt == null || moved.isAfter(row.lastSoldAt!))
                'dernier mouvement ${formatDate(moved)}',
          ].join(' · '),
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
        // Sans prix d'achat connu, aucune valeur n'est inventée.
        trailing: value == null
            ? Text(
                'valeur inconnue',
                style: AmpereType.meta.copyWith(color: colors.ink3),
              )
            : Text(formatDA(value), style: AmpereType.rowTitle),
      ),
    );
  }
}

class _DemandTab extends ConsumerWidget {
  const _DemandTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final days = ref.watch(demandDaysProvider);
    final demand = ref.watch(productDemandProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 12, margin, 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _DaysChips(
              value: days,
              choices: const [7, 30, 90, 365],
              onChanged: (value) =>
                  ref.read(demandDaysProvider.notifier).set(value),
            ),
          ),
        ),
        Expanded(
          child: demand.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException
                  ? error.userMessage
                  : 'Le rapport n’a pas pu être chargé.',
              onRetry: () => ref.invalidate(productDemandProvider),
            ),
            data: (data) => ListView(
              padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
              children: [
                _DemandSection(
                  title: 'Les plus vendus',
                  hint: 'Ventes validées sur $days jours.',
                  lines: data.bestSellers,
                  withRevenue: true,
                ),
                _DemandSection(
                  title: 'Les plus demandés au dépôt',
                  hint: 'Quantités réclamées par le magasin.',
                  lines: data.mostRequested,
                ),
                _DemandSection(
                  title: 'Demandés et NON servis',
                  hint:
                      'Ce qui manquait à la préparation : la demande qu’une '
                      'rupture a fait perdre.',
                  lines: data.unmetDemand,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DemandSection extends StatelessWidget {
  const _DemandSection({
    required this.title,
    required this.hint,
    required this.lines,
    this.withRevenue = false,
  });

  final String title;
  final String hint;
  final List<DemandLine> lines;
  final bool withRevenue;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: AmpereType.rowTitle),
            const SizedBox(height: 2),
            Text(hint, style: AmpereType.meta.copyWith(color: colors.ink3)),
            const SizedBox(height: 10),
            if (lines.isEmpty)
              Text(
                'Rien sur la période.',
                style: AmpereType.meta.copyWith(color: colors.ink3),
              )
            else
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Expanded(child: Text(line.name)),
                      Text(
                        '${formatQuantity(quantityFromJson(line.quantity))} '
                        '${productUnitShort(line.unit)}',
                        style: AmpereType.meta,
                      ),
                      // Parenthèses indispensables : sans elles, `&&` capture
                      // `line.revenueHt` avant le `case` et la condition teste
                      // un booléen au lieu d'un montant.
                      if (withRevenue)
                        if (line.revenueHt case final revenue?)
                          Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: Text(
                              formatDA(revenue),
                              style: AmpereType.meta,
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
