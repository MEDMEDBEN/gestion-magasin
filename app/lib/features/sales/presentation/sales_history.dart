import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/quantity.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/application/catalog_controller.dart';
import '../application/sales_controller.dart';
import '../data/sales_api.dart';
import '../data/sales_models.dart';
import '../../../ui/widgets/period_filter.dart';
import 'contact_card.dart';
import 'sale_return_dialog.dart';
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

class _SalesHistorySectionState extends ConsumerState<SalesHistorySection> {
  final _search = TextEditingController();
  String _query = '';
  HistoryPeriod _period = lastDays(7);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  SalesHistoryFilter get _filter => (q: _query, period: _period);

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
              PeriodFilter(
                value: _period,
                onChanged: (p) => setState(() => _period = p),
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
                      _summary(page.data),
                      const SizedBox(height: 14),
                      // Regroupées par jour, la plus récente d'abord.
                      for (final (day, sales) in _byDay(page.data)) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 6, 2, 8),
                          child: Text(
                            day,
                            style: AmpereType.label.copyWith(
                              color: AmpereColors.of(context).ink3,
                              letterSpacing: 1.1,
                            ),
                          ),
                        ),
                        for (final sale in sales)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _SaleTile(
                              sale: sale,
                              seller:
                                  widget.rights.canSeeAllCash &&
                                      sale.sellerName.isNotEmpty
                                  ? sale.sellerName
                                  : null,
                              onTap: () => showSaleDetail(
                                context,
                                sale: sale,
                                rights: widget.rights,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

extension on _SalesHistorySectionState {
  /// Les chiffres de la liste affichée (ventes annulées exclues).
  Widget _summary(List<Sale> sales) {
    final colors = AmpereColors.of(context);
    final valid = sales.where((s) => s.status != 'ANNULEE').toList();
    final remaining = valid.fold(0, (sum, s) => sum + s.remainingAmount);
    return SummaryStrip(
      items: [
        ('Ventes', '${valid.length}', colors.accentHi),
        (
          'Chiffre d’affaires',
          formatDA(valid.fold(0, (sum, s) => sum + s.totalTtc)),
          colors.ok,
        ),
        if (remaining > 0)
          ('Reste à encaisser', formatDA(remaining), colors.warn),
      ],
    );
  }
}

/// « AUJOURD'HUI », « HIER » ou la date : les ventes d'un même jour ensemble
/// (l'ordre reçu du serveur — plus récente d'abord — est gardé).
List<(String, List<Sale>)> _byDay(List<Sale> sales) {
  final now = DateTime.now();
  String label(DateTime at) {
    final d = DateUtils.dateOnly(at.toLocal());
    final today = DateUtils.dateOnly(now);
    if (d == today) return 'AUJOURD’HUI';
    if (d == today.subtract(const Duration(days: 1))) return 'HIER';
    return formatDate(d);
  }

  final groups = <(String, List<Sale>)>[];
  for (final sale in sales) {
    final day = label(sale.soldAt);
    if (groups.isEmpty || groups.last.$1 != day) groups.add((day, []));
    groups.last.$2.add(sale);
  }
  return groups;
}

/// Une vente en mini-ticket : nature (ticket, facture, annulée) en couleur,
/// heure, client, montant et état du paiement.
class _SaleTile extends StatelessWidget {
  const _SaleTile({required this.sale, required this.onTap, this.seller});

  final Sale sale;
  final String? seller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final cancelled = sale.status == 'ANNULEE';
    final invoice = sale.invoiceNumber != null || sale.type == 'FACTURE';
    final (IconData icon, Color tone, String state) = cancelled
        ? (LucideIcons.ban, colors.error, 'Annulée')
        : sale.remainingAmount > 0
        ? (
            invoice ? LucideIcons.fileText : LucideIcons.receipt,
            colors.warn,
            'Reste ${formatDA(sale.remainingAmount)}',
          )
        : (
            invoice ? LucideIcons.fileText : LucideIcons.receipt,
            colors.ok,
            'Payée',
          );
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: tone),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            saleTitle(sale),
                            overflow: TextOverflow.ellipsis,
                            style: AmpereType.rowTitle.copyWith(
                              color: colors.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: invoice ? colors.accentBg : colors.surface3,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            invoice ? 'Facture' : 'Ticket',
                            style: AmpereType.label.copyWith(
                              color: invoice ? colors.accentHi : colors.ink2,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        formatTime(sale.soldAt),
                        sale.customerName ?? 'Client de passage',
                        ?seller,
                      ].join(' · '),
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.meta.copyWith(color: colors.ink2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatDA(sale.totalTtc),
                    style: AmpereType.bodyStrong.copyWith(
                      color: cancelled ? colors.ink3 : colors.ink,
                      fontFeatures: AmpereType.tabular,
                      decoration: cancelled ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(state, style: AmpereType.label.copyWith(color: tone)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// « FA-2026-000012 (TK-2026-000042) » pour une vente facturée, sinon le
/// numéro du ticket.
String saleTitle(Sale sale) => sale.invoiceNumber == null
    ? sale.number
    : '${sale.invoiceNumber} (${sale.number})';

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
  late Future<List<SaleReturn>> _returns = ref
      .read(salesApiProvider)
      .saleReturns(widget.sale.id);
  // Des articles déjà revenus : la vente ne se facture ni ne s'annule plus
  // (miroir des gardes serveur).
  bool _hasReturns = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _watchReturns();
  }

  void _watchReturns() => _returns.then((r) {
    if (mounted) setState(() => _hasReturns = r.isNotEmpty);
  }, onError: (_) {});

  /// Retour d'articles (ADMIN, P1 bis n°21l), puis vente et retours relus.
  Future<void> _returnItems() async {
    final previous = await _returns.catchError((_) => <SaleReturn>[]);
    if (!mounted) return;
    final done = await showSaleReturnDialog(
      context,
      sale: _sale,
      previous: previous,
    );
    if (done == null || !mounted) return;
    final api = ref.read(salesApiProvider);
    final fresh = await api.sale(_sale.id).catchError((_) => _sale);
    if (!mounted) return;
    setState(() {
      _sale = fresh;
      _returns = api.saleReturns(_sale.id);
    });
    _watchReturns();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Retour ${done.creditNoteNumber ?? done.number} enregistré — '
          '${formatDA(done.totalTtc)}',
        ),
      ),
    );
  }

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
                          ' × ${formatQuantity(line.quantity)}'
                          '${line.discountAmount > 0 ? ' · remise ${formatDA(line.discountAmount)} HT' : ''}',
                        ),
                      ),
                      Text(formatDA(line.lineTotalTtc)),
                    ],
                  ),
                ),
              const Divider(height: 20),
              // Vente d'avant le retrait de la TVA (2026-10-05) : ventilée.
              if (sale.totalTax > 0) ...[
                Text('Total HT : ${formatDA(sale.totalHt)}'),
                Text('TVA : ${formatDA(sale.totalTax)}'),
              ],
              Text(
                '${sale.totalTax > 0 ? 'Total TTC' : 'Total'} : '
                '${formatDA(sale.totalTtc)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text('Encaissé à la vente : ${formatDA(sale.paidAmount)}'),
              if (!cancelled && sale.remainingAmount > 0)
                Text(
                  'Reste dû : ${formatDA(sale.remainingAmount)}'
                  '${sale.dueDate == null ? '' : ' · échéance ${formatDate(sale.dueDate!)}'}',
                ),
              FutureBuilder<List<SaleReturn>>(
                future: _returns,
                builder: (context, snapshot) {
                  final returns = snapshot.data ?? const <SaleReturn>[];
                  if (returns.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 20),
                      const Text('Retours'),
                      for (final r in returns)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${r.creditNoteNumber ?? r.number} · '
                                '${formatDateTime(r.createdAt)} · '
                                '${formatDA(r.totalTtc)} · '
                                '${r.refundMethod == 'ESPECES' ? 'remboursé' : 'déduit de la dette'}',
                              ),
                            ),
                            IconButton(
                              tooltip: 'Imprimer l’avoir',
                              icon: const Icon(Icons.print_outlined, size: 18),
                              onPressed: _busy
                                  ? null
                                  : () => _run(
                                      () => ref
                                          .read(salesActionsProvider)
                                          .printReturn(r),
                                    ),
                            ),
                          ],
                        ),
                    ],
                  );
                },
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
        // Retour partiel (ADMIN + sale.cancel) : facturée ou non ; une vente
        // facturée reçoit alors une facture d'avoir.
        if (widget.rights.canCancelSales && !cancelled)
          TextButton(
            onPressed: _busy ? null : _returnItems,
            child: const Text('Retour d’articles'),
          ),
        // Miroir des gardes serveur : annulation ADMIN + sale.cancel ; une
        // vente facturée ne s'annule pas (elle passe par un avoir).
        if (widget.rights.canCancelSales &&
            !cancelled &&
            !_hasReturns &&
            sale.invoiceNumber == null)
          TextButton(
            onPressed: _busy ? null : _cancel,
            child: const Text('Annuler la vente'),
          ),
        if (widget.rights.canInvoice &&
            !cancelled &&
            !_hasReturns &&
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
