import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/file_export.dart';
import '../../../core/money.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/export_button.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/business_reports_controller.dart';
import '../data/business_report_models.dart';
import '../data/business_reports_api.dart';

/// Rapports ventes / stock / achats (spec §21).
///
/// ADMIN seul — le serveur le revérifie. L'écran reste un RÉSUMÉ : la spec dit
/// « ne pas surcharger », et les listes détaillées ont déjà leurs écrans.
class BusinessReportsScreen extends ConsumerWidget {
  const BusinessReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final days = ref.watch(reportRangeProvider);

    return ListView(
      padding: EdgeInsets.fromLTRB(margin, 12, margin, 24),
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final choice in const [7, 30, 90, 365])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('$choice j'),
                    selected: days == choice,
                    onSelected: (on) {
                      if (on) {
                        ref.read(reportRangeProvider.notifier).set(choice);
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const _SalesCard(),
        const SizedBox(height: 12),
        const _StockCard(),
        const SizedBox(height: 12),
        const _PurchasesCard(),
        const SizedBox(height: 12),
        Text(
          'Le stock est un état, pas un flux : sa valeur ne dépend pas de la '
          'période choisie.',
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
      ],
    );
  }
}

/// Coquille commune : titre, état de chargement, erreur, et le contenu.
class _ReportCard<T> extends StatelessWidget {
  const _ReportCard({
    required this.title,
    required this.value,
    required this.onRetry,
    required this.builder,
    required this.onExport,
  });

  final String title;
  final Future<ExportedFile> Function(ExportFormat format) onExport;
  final AsyncValue<T> value;
  final VoidCallback onRetry;
  final Widget Function(BuildContext context, T data) builder;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: AmpereType.rowTitle)),
                ExportButton(fetch: onExport),
              ],
            ),
            const SizedBox(height: 4),
            value.when(
              loading: () => const _CardSkeleton(),
              error: (error, _) => ScreenStateView(
                status: error is ApiException && error.isOffline
                    ? ScreenStatus.offline
                    : ScreenStatus.error,
                message: error is ApiException
                    ? error.userMessage
                    : 'Ce rapport n’a pas pu être chargé.',
                onRetry: onRetry,
              ),
              data: (data) => builder(context, data),
            ),
          ],
        ),
      ),
    );
  }
}

/// Squelette de chargement BORNÉ. Pas `AmpereSkeletonList` : c'est un
/// `ListView`, et l'imbriquer dans le `ListView` de l'écran fait planter le
/// calcul de mise en page (« Vertical viewport was given unbounded height ») —
/// l'écran tombait pendant sa première frame, trouvé par le test.
class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final width in const [0.55, 0.35])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: width,
              child: Container(height: 14, color: colors.surface2),
            ),
          ),
      ],
    );
  }
}

/// Une grandeur et son libellé. `null` s'affiche « — » et jamais « 0 DA » : un
/// zéro se lirait comme un fait, alors que c'est une inconnue.
class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, this.hint});

  final String label;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AmpereType.meta.copyWith(color: colors.ink3)),
          Text(value, style: AmpereType.rowTitle),
          if (hint case final text?)
            Text(text, style: AmpereType.meta.copyWith(color: colors.ink3)),
        ],
      ),
    );
  }
}

/// Exporte la fenêtre CHOISIE à l'écran, celle que la carte affiche.
Future<ExportedFile> _exportForRange(
  WidgetRef ref,
  String report,
  ExportFormat format,
) {
  final range = rangeFor(ref.read(reportRangeProvider));
  return ref
      .read(businessReportsApiProvider)
      .export(report, format, from: range.from, to: range.to);
}

String _moneyOrDash(int? centimes) =>
    centimes == null ? '—' : formatDA(centimes);

class _SalesCard extends ConsumerWidget {
  const _SalesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    return _ReportCard<SalesReport>(
      title: 'Ventes',
      value: ref.watch(salesReportProvider),
      onRetry: () => ref.invalidate(salesReportProvider),
      onExport: (format) => _exportForRange(ref, 'sales', format),
      builder: (context, data) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Du ${data.period.from} au ${data.period.to} '
            '(${data.period.days} j) · ventes validées seulement · '
            'marge au dernier prix d’achat',
            style: AmpereType.meta.copyWith(color: colors.ink3),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 24,
            children: [
              _Figure(label: 'Ventes', value: '${data.totals.count}'),
              _Figure(
                label: 'Chiffre d’affaires HT',
                value: formatDA(data.totals.revenueHt),
                hint: '${formatDA(data.totals.revenueTtc)} TTC',
              ),
              _Figure(
                label: 'Marge HT',
                value: _moneyOrDash(data.totals.marginHt),
                // Dire POURQUOI c'est vide : sans ça on croit à une panne.
                hint: data.totals.marginHt == null
                    ? 'coût d’achat inconnu'
                    : 'coût ${formatDA(data.totals.costHt!)}',
              ),
              _Figure(
                label: 'TVA collectée',
                value: formatDA(data.totals.taxAmount),
              ),
              if (data.totals.discountAmount > 0)
                _Figure(
                  label: 'Remises',
                  value: formatDA(data.totals.discountAmount),
                ),
            ],
          ),
          // Sans ce rappel, une marge calculée sur une partie du CA se lirait
          // comme la marge de toute la période.
          if (data.totals.marginHt != null && data.totals.uncostedRevenueHt > 0)
            Text(
              'Marge calculée hors ${formatDA(data.totals.uncostedRevenueHt)} '
              'de ventes sans coût d’achat connu.',
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
          if (data.byCategory.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Par catégorie',
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
            const SizedBox(height: 4),
            for (final row in data.byCategory.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(row.categoryName)),
                    Text(
                      formatQuantity(quantityFromJson(row.quantity)),
                      style: AmpereType.meta.copyWith(color: colors.ink3),
                    ),
                    const SizedBox(width: 12),
                    Text(formatDA(row.revenueHt), style: AmpereType.meta),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _StockCard extends ConsumerWidget {
  const _StockCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    return _ReportCard<StockReport>(
      title: 'Stock',
      value: ref.watch(stockReportProvider),
      onRetry: () => ref.invalidate(stockReportProvider),
      onExport: (format) =>
          ref.read(businessReportsApiProvider).export('stock', format),
      builder: (context, data) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 24,
            children: [
              _Figure(
                label: 'Valeur au dernier prix d’achat',
                value: _moneyOrDash(data.valueHt),
                hint: data.withoutCostCount == 0
                    ? null
                    : '${data.withoutCostCount} référence(s) sans coût connu, '
                          'hors total',
              ),
              _Figure(
                label: 'Références en stock',
                value: '${data.referenceCount}',
              ),
              _Figure(label: 'Stock faible', value: '${data.lowCount}'),
              _Figure(label: 'Ruptures', value: '${data.outOfStockCount}'),
            ],
          ),
          for (final row in data.byLocation)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(child: Text(row.locationName)),
                  Text(
                    '${row.referenceCount} réf.',
                    style: AmpereType.meta.copyWith(color: colors.ink3),
                  ),
                  const SizedBox(width: 12),
                  Text(_moneyOrDash(row.valueHt), style: AmpereType.meta),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PurchasesCard extends ConsumerWidget {
  const _PurchasesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    return _ReportCard<PurchasesReport>(
      title: 'Achats',
      value: ref.watch(purchasesReportProvider),
      onRetry: () => ref.invalidate(purchasesReportProvider),
      onExport: (format) => _exportForRange(ref, 'purchases', format),
      builder: (context, data) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 24,
            children: [
              _Figure(
                label: 'Commandé HT',
                value: formatDA(data.orderedHt),
                hint: '${data.orderCount} commande(s)',
              ),
              _Figure(
                label: 'Réceptionné HT',
                value: formatDA(data.receivedHt),
                hint: '${data.receptionCount} réception(s)',
              ),
            ],
          ),
          // Dit une fois, clairement : sans ça on cherche pourquoi les deux
          // chiffres ne se répondent pas.
          Text(
            'Commandé et réceptionné ne s’équilibrent pas : une commande de ce '
            'mois peut être reçue le mois suivant.',
            style: AmpereType.meta.copyWith(color: colors.ink3),
          ),
          if (data.bySupplier.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final row in data.bySupplier.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(row.supplierName)),
                    Text(formatDA(row.orderedHt), style: AmpereType.meta),
                    const SizedBox(width: 12),
                    Text(
                      'reçu ${formatDA(row.receivedHt)}',
                      style: AmpereType.meta.copyWith(color: colors.ink3),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
