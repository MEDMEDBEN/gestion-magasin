import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';

/// HISTORIQUE DES PRIX d'un produit (demande MEDMEDBEN du 2026-11-16) : ce
/// qu'il a été PAYÉ à chaque réception (fournisseur, date) et l'évolution de
/// ses prix de VENTE (tarifs). Lu en ligne.
Future<void> showProductPriceHistory(
  BuildContext context,
  WidgetRef ref,
  Product product,
) => showDialog<void>(
  context: context,
  builder: (_) => _PriceHistoryDialog(product: product),
);

class _PriceHistoryDialog extends ConsumerWidget {
  const _PriceHistoryDialog({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final api = ref.read(catalogApiProvider);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: DefaultTabController(
          length: 2,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
                child: Row(
                  children: [
                    Icon(LucideIcons.history, color: colors.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Historique des prix — ${product.name}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AmpereType.h4.copyWith(color: colors.ink),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Fermer',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(LucideIcons.x, size: 19),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'Prix d’achat'),
                  Tab(text: 'Prix de vente'),
                ],
              ),
              Flexible(
                child: TabBarView(
                  children: [
                    _Rows(
                      empty: 'Aucune réception de ce produit pour l’instant.',
                      header: product.lastPurchasePriceHt == null
                          ? null
                          : 'Dernier prix d’achat : '
                                '${formatDA(product.lastPurchasePriceHt!)} HT',
                      load: () async => [
                        for (final r in await api.costHistory(product.id))
                          (
                            title: formatDA(r['unitPriceHt'] as int),
                            subtitle:
                                '${r['supplierName']} · ${r['receptionNumber']}'
                                ' · ${formatDate(DateTime.parse(r['at'] as String).toLocal())}',
                            trailing: '× ${r['quantity']}',
                          ),
                      ],
                    ),
                    _Rows(
                      empty: 'Aucun changement de prix de vente enregistré.',
                      load: () async => [
                        for (final h in await api.priceHistory(product.id))
                          (
                            title:
                                '${h['oldPriceHt'] == null ? 'Premier prix' : formatDA(h['oldPriceHt'] as int)} → ${formatDA(h['newPriceHt'] as int)}',
                            subtitle: [
                              h['tier'] as String,
                              formatDateTime(
                                DateTime.parse(h['at'] as String).toLocal(),
                              ),
                              if (h['by'] != null) h['by'] as String,
                            ].join(' · '),
                            trailing: '',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _Row = ({String title, String subtitle, String trailing});

class _Rows extends StatefulWidget {
  const _Rows({required this.load, required this.empty, this.header});

  final Future<List<_Row>> Function() load;
  final String empty;
  final String? header;

  @override
  State<_Rows> createState() => _RowsState();
}

class _RowsState extends State<_Rows> {
  late final Future<List<_Row>> _rows = widget.load();

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return FutureBuilder<List<_Row>>(
      future: _rows,
      builder: (context, snap) {
        if (snap.hasError) {
          final e = snap.error;
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Text(e is ApiException ? e.userMessage : '$e'),
          );
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final rows = snap.data!;
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          children: [
            if (widget.header != null) ...[
              Text(
                widget.header!,
                style: AmpereType.bodyStrong.copyWith(color: colors.ink),
              ),
              const SizedBox(height: 8),
            ],
            if (rows.isEmpty)
              Text(
                widget.empty,
                style: AmpereType.body.copyWith(color: colors.ink3),
              ),
            for (final (i, r) in rows.indexed)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: i == 0
                      ? null
                      : Border(top: BorderSide(color: colors.lineSoft)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.title,
                            style: AmpereType.bodyStrong.copyWith(
                              color: colors.ink,
                              fontFeatures: AmpereType.tabular,
                            ),
                          ),
                          Text(
                            r.subtitle,
                            style: AmpereType.meta.copyWith(color: colors.ink3),
                          ),
                        ],
                      ),
                    ),
                    if (r.trailing.isNotEmpty)
                      Text(
                        r.trailing,
                        style: AmpereType.meta.copyWith(color: colors.ink2),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
