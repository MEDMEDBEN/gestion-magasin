import 'package:flutter/material.dart';

import '../../../../core/quantity.dart';
import '../../../../ui/theme/ampere_colors.dart';
import '../../../../ui/theme/ampere_typography.dart';
import '../../../../ui/widgets/ampere_controls.dart';
import '../../../../ui/widgets/screen_state.dart';
import '../../data/catalog_models.dart';

/// Tableau desktop dense (AMPÈRE §6) : référence et code-barres en mono,
/// seuil en chiffres tabulaires alignés à droite, ligne entière cliquable.
/// Construit à la demande : un catalogue de milliers de lignes reste fluide.
class ProductsTable extends StatelessWidget {
  const ProductsTable({
    super.key,
    required this.products,
    required this.categoryNames,
    required this.onTap,
  });

  final List<Product> products;
  final Map<String, String> categoryNames;
  final void Function(Product product) onTap;

  static const double _minWidth = 900;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        const margin = AmpereGeometry.screenMarginDesktop;
        final width =
            (constraints.maxWidth < _minWidth
                ? _minWidth
                : constraints.maxWidth) -
            margin * 2;
        return Padding(
          padding: const EdgeInsets.fromLTRB(margin, 0, margin, margin),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: Column(
                  children: [
                    const _HeaderRow(),
                    Divider(height: 1, color: colors.line),
                    Expanded(
                      child: ListView.separated(
                        itemCount: products.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, color: colors.lineSoft),
                        itemBuilder: (context, i) => _ProductRow(
                          product: products[i],
                          category: categoryNames[products[i].categoryId],
                          onTap: () => onTap(products[i]),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Columns {
  static const sku = 3;
  static const name = 6;
  static const category = 3;
  static const barcode = 3;
  static const threshold = 2;
  static const status = 2;
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = AmpereType.label.copyWith(
      color: AmpereColors.of(context).ink3,
    );
    Widget cell(String text, int flex, {bool end = false}) => Expanded(
      flex: flex,
      child: Text(
        text.toUpperCase(),
        textAlign: end ? TextAlign.end : TextAlign.start,
        style: style,
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          cell('Référence', _Columns.sku),
          cell('Désignation', _Columns.name),
          cell('Catégorie', _Columns.category),
          cell('Code-barres', _Columns.barcode),
          cell('Seuil min.', _Columns.threshold, end: true),
          const SizedBox(width: 16),
          cell('Statut', _Columns.status),
        ],
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({
    required this.product,
    required this.category,
    required this.onTap,
  });

  final Product product;
  final String? category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    Text ellipsis(String text, TextStyle style) =>
        Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);

    return AmpereTappable(
      onTap: onTap,
      borderRadius: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              flex: _Columns.sku,
              child: ellipsis(
                product.sku,
                AmpereType.mono.copyWith(color: colors.ink2),
              ),
            ),
            Expanded(
              flex: _Columns.name,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ellipsis(
                    product.name,
                    AmpereType.bodyStrong.copyWith(color: colors.ink),
                  ),
                  if (product.brand != null)
                    ellipsis(
                      product.brand!,
                      AmpereType.metaDesktop.copyWith(color: colors.ink3),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: _Columns.category,
              child: ellipsis(
                category ?? '—',
                AmpereType.bodyDesktop.copyWith(
                  color: category == null ? colors.ink3 : colors.ink2,
                ),
              ),
            ),
            Expanded(
              flex: _Columns.barcode,
              child: ellipsis(
                product.barcode,
                AmpereType.mono.copyWith(color: colors.ink3),
              ),
            ),
            Expanded(
              flex: _Columns.threshold,
              child: Text(
                '${formatQuantity(product.minThreshold)} ${product.unit.short}',
                textAlign: TextAlign.end,
                style: AmpereType.bodyDesktop.copyWith(
                  color: colors.ink2,
                  fontFeatures: AmpereType.tabular,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: _Columns.status,
              child: Align(
                alignment: Alignment.centerLeft,
                child: product.isActive
                    ? const AmpereBadge(label: 'Actif', tone: StatusTone.ok)
                    : const AmpereBadge(
                        label: 'Inactif',
                        tone: StatusTone.neutral,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
