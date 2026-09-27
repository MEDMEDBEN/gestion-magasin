import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/application/catalog_controller.dart';
import '../application/sales_controller.dart';
import '../data/sales_models.dart';
import 'sales_screen.dart';

/// Historique des ventes (spec §8, P1 bis n°21d) : retrouver une vente passée,
/// la réimprimer, facturer un ticket après coup, l'annuler (ADMIN). Le vendeur
/// ne voit que SES ventes (le serveur filtre). Les ventes encore en file sur ce
/// poste n'y sont pas : elles ne sont pas définitives (règle 8).
class SalesHistorySection extends ConsumerStatefulWidget {
  const SalesHistorySection({
    required this.margin,
    required this.rights,
    super.key,
  });

  final double margin;
  final SalesRights rights;

  @override
  ConsumerState<SalesHistorySection> createState() =>
      _SalesHistorySectionState();
}

/// Périodes proposées : aujourd'hui, 7 jours, 30 jours, tout.
const _periods = <(String, int?)>[
  ('Aujourd’hui', 1),
  ('7 jours', 7),
  ('30 jours', 30),
  ('Tout', null),
];

class _SalesHistorySectionState extends ConsumerState<SalesHistorySection> {
  final _search = TextEditingController();
  String _query = '';
  int? _days = 7;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  SalesHistoryFilter get _filter => (q: _query, days: _days);

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(salesHistoryProvider(_filter));
    final margin = widget.margin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'N° de ticket, de facture ou client',
                  ),
                  onSubmitted: (value) => setState(() => _query = value),
                ),
              ),
              SegmentedButton<int?>(
                showSelectedIcon: false,
                segments: [
                  for (final (label, days) in _periods)
                    ButtonSegment(value: days, label: Text(label)),
                ],
                selected: {_days},
                onSelectionChanged: (s) => setState(() => _days = s.first),
              ),
            ],
          ),
        ),
        Expanded(
          child: history.when(
            loading: () => const AmpereSkeletonList(rows: 6),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException ? error.userMessage : '$error',
              onRetry: () => ref.invalidate(salesHistoryProvider(_filter)),
            ),
            data: (page) => page.data.isEmpty
                ? ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Aucune vente',
                    message: _query.isEmpty
                        ? 'Aucune vente sur cette période.'
                        : 'Aucune vente ne correspond à « $_query ».',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      if (page.meta.total > page.data.length)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '${page.data.length} ventes les plus récentes sur '
                            '${page.meta.total} — affinez la période ou la '
                            'recherche.',
                          ),
                        ),
                      for (final sale in page.data)
                        Card(
                          child: ListTile(
                            title: Text(saleTitle(sale)),
                            subtitle: Text(
                              [
                                formatDateTime(sale.soldAt),
                                sale.customerName ?? 'Client de passage',
                                if (widget.rights.canSeeAllCash &&
                                    sale.sellerName.isNotEmpty)
                                  sale.sellerName,
                              ].join(' · '),
                            ),
                            trailing: _SaleBadge(sale: sale),
                            onTap: () => showSaleDetail(
                              context,
                              sale: sale,
                              rights: widget.rights,
                            ),
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

/// « FA-2026-000012 (TK-2026-000042) » pour une vente facturée, sinon le
/// numéro du ticket.
String saleTitle(Sale sale) => sale.invoiceNumber == null
    ? sale.number
    : '${sale.invoiceNumber} (${sale.number})';

class _SaleBadge extends StatelessWidget {
  const _SaleBadge({required this.sale});

  final Sale sale;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = sale.status == 'ANNULEE'
        ? ('Annulée', StatusTone.error)
        : sale.remainingAmount > 0
        ? ('Reste ${formatDA(sale.remainingAmount)}', StatusTone.warn)
        : (formatDA(sale.totalTtc), StatusTone.ok);
    return AmpereBadge(label: label, tone: tone);
  }
}

/// Détail d'une vente : lignes, totaux, et les gestes permis.
Future<void> showSaleDetail(
  BuildContext context, {
  required Sale sale,
  required SalesRights rights,
}) => showDialog<void>(
  context: context,
  builder: (context) => _SaleDetailDialog(sale: sale, rights: rights),
);

class _SaleDetailDialog extends ConsumerStatefulWidget {
  const _SaleDetailDialog({required this.sale, required this.rights});

  final Sale sale;
  final SalesRights rights;

  @override
  ConsumerState<_SaleDetailDialog> createState() => _SaleDetailDialogState();
}

class _SaleDetailDialogState extends ConsumerState<_SaleDetailDialog> {
  late Sale _sale = widget.sale;
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.userMessage);
    } on Exception {
      if (mounted) {
        setState(() => _error = 'Impression impossible sur ce poste.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Annuler ${_sale.number} ?'),
        content: const Text(
          'Les articles reviennent en stock et les espèces encaissées sortent '
          'de la caisse. La vente reste dans l’historique, marquée annulée.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Garder la vente'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Annuler la vente'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      final cancelled = await ref.read(salesActionsProvider).cancel(_sale.id);
      if (mounted) setState(() => _sale = cancelled);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sale = _sale;
    final cancelled = sale.status == 'ANNULEE';
    final products = {
      for (final p
          in ref.watch(activeProductsProvider).value ?? const <Never>[])
        p.id: p,
    };
    final actions = ref.read(salesActionsProvider);
    return AlertDialog(
      title: Text(saleTitle(sale)),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                [
                  formatDateTime(sale.soldAt),
                  sale.customerName ?? 'Client de passage',
                  if (sale.sellerName.isNotEmpty) 'vendeur ${sale.sellerName}',
                ].join(' · '),
              ),
              if (cancelled)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Annulée${sale.cancelledAt == null ? '' : ' le ${formatDateTime(sale.cancelledAt!)}'}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const Divider(height: 20),
              for (final line in sale.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${products[line.productId]?.name ?? 'Produit retiré du catalogue'}'
                          ' × ${formatQuantity(line.quantity)}',
                        ),
                      ),
                      Text(formatDA(line.lineTotalTtc)),
                    ],
                  ),
                ),
              const Divider(height: 20),
              Text('Total HT : ${formatDA(sale.totalHt)}'),
              Text('TVA : ${formatDA(sale.totalTax)}'),
              Text(
                'Total TTC : ${formatDA(sale.totalTtc)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text('Encaissé à la vente : ${formatDA(sale.paidAmount)}'),
              if (!cancelled && sale.remainingAmount > 0)
                Text(
                  'Reste dû : ${formatDA(sale.remainingAmount)}'
                  '${sale.dueDate == null ? '' : ' · échéance ${formatDate(sale.dueDate!)}'}',
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        // Miroir des gardes serveur : annulation ADMIN + sale.cancel ; une
        // vente facturée ne s'annule pas (il faudra un avoir, P1 bis n°21l).
        if (widget.rights.canCancelSales &&
            !cancelled &&
            sale.invoiceNumber == null)
          TextButton(
            onPressed: _busy ? null : _cancel,
            child: const Text('Annuler la vente'),
          ),
        if (widget.rights.canInvoice &&
            !cancelled &&
            sale.invoiceNumber == null)
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final invoiced = await actions.invoice(sale.id);
                    if (mounted) setState(() => _sale = invoiced);
                  }),
            child: const Text('Émettre la facture'),
          ),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _run(() => actions.printDocument(sale)),
          icon: const Icon(Icons.print_outlined, size: 18),
          label: Text(
            sale.invoiceNumber == null
                ? 'Réimprimer le ticket'
                : 'Réimprimer la facture',
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}
