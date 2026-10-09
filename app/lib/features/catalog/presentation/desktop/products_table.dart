import 'package:flutter/material.dart';

import '../../../../core/money.dart';
import '../../../../core/quantity.dart';
import '../../../../ui/theme/ampere_colors.dart';
import '../../../../ui/theme/ampere_typography.dart';
import '../../../../ui/widgets/ampere_controls.dart';
import '../../../../ui/widgets/screen_state.dart';
import '../../../stock/application/stock_controller.dart';
import '../../../stock/presentation/stock_status.dart';
import '../../data/catalog_models.dart';
import '../product_photo.dart';
import '../product_row_actions.dart';

/// Tableau desktop dense (AMPÈRE §6) : référence et code-barres en mono,
/// seuil en chiffres tabulaires alignés à droite, ligne entière cliquable.
/// Construit à la demande : un catalogue de milliers de lignes reste fluide.
class ProductsTable extends StatelessWidget {
  const ProductsTable({
    super.key,
    required this.products,
    required this.categoryNames,
    required this.onTap,
    this.stock,
    this.defaultTierId,
    this.onEdit,
    this.onDelete,
    this.onLabel,
    this.selection,
    this.onToggle,
  });

  /// `null` sans le droit : le bouton n'apparaît pas.
  final void Function(Product product)? onEdit;
  final void Function(Product product)? onDelete;
  final void Function(Product product)? onLabel;

  /// Mode sélection : produits cochés (`null` = mode désactivé).
  final Set<String>? selection;
  final void Function(Product product)? onToggle;

  /// Tarif par défaut : son prix est le « prix de vente » affiché.
  final String? defaultTierId;

  final List<Product> products;
  final Map<String, String> categoryNames;
  final void Function(Product product) onTap;

  /// Stock par produit — `null` si non chargé ou non autorisé.
  final Map<String, ProductStock>? stock;

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
                    _HeaderRow(
                      actions:
                          onEdit != null || onDelete != null || onLabel != null,
                    ),
                    Divider(height: 1, color: colors.line),
                    Expanded(
                      child: ListView.separated(
                        itemCount: products.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, color: colors.lineSoft),
                        itemBuilder: (context, i) => _ProductRow(
                          product: products[i],
                          category: categoryNames[products[i].categoryId],
                          stock: stock,
                          defaultTierId: defaultTierId,
                          onTap: () => onTap(products[i]),
                          onEdit: onEdit,
                          onDelete: onDelete,
                          onLabel: onLabel,
                          selected: selection?.contains(products[i].id),
                          onToggle: onToggle == null
                              ? null
                              : () => onToggle!(products[i]),
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

/// Colonne des boutons Modifier / Supprimer.
const double _actionsWidth = 150;

class _Columns {
  static const name = 8;
  static const category = 3;
  static const barcode = 3;
  static const sale = 2;
  static const cost = 2;
  static const status = 3;
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.actions});

  final bool actions;

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
          cell('Produit', _Columns.name),
          cell('Catégorie', _Columns.category),
          cell('Code-barres', _Columns.barcode),
          cell('Prix vente', _Columns.sale, end: true),
          cell('Prix achat', _Columns.cost, end: true),
          const SizedBox(width: 16),
          cell('Stock', _Columns.status),
          if (actions) const SizedBox(width: _actionsWidth),
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
    required this.stock,
    this.defaultTierId,
    this.onEdit,
    this.onDelete,
    this.onLabel,
    this.selected,
    this.onToggle,
  });

  final Product product;
  final String? category;
  final VoidCallback onTap;
  final String? defaultTierId;
  final Map<String, ProductStock>? stock;
  final void Function(Product product)? onEdit;
  final void Function(Product product)? onDelete;
  final void Function(Product product)? onLabel;

  /// Mode sélection : coché ou non (`null` = mode désactivé).
  final bool? selected;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    Text ellipsis(String text, TextStyle style) =>
        Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);

    return AmpereTappable(
      onTap: selected != null ? onToggle : onTap,
      borderRadius: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            if (selected != null)
              Checkbox(value: selected, onChanged: (_) => onToggle?.call()),
            // Produit : photo, nom, référence · marque — un seul coup d'œil.
            Expanded(
              flex: _Columns.name,
              child: Row(
                children: [
                  ProductThumbnail(product: product, size: 38),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ellipsis(
                          product.name,
                          AmpereType.bodyStrong.copyWith(color: colors.ink),
                        ),
                        ellipsis(
                          [product.sku, ?product.brand].join(' · '),
                          AmpereType.metaDesktop.copyWith(color: colors.ink3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: _Columns.category,
              child: Align(
                alignment: Alignment.centerLeft,
                child: category == null
                    ? Text('—', style: TextStyle(color: colors.ink3))
                    : Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surface2,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ellipsis(
                          category!,
                          AmpereType.metaDesktop.copyWith(color: colors.ink2),
                        ),
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
            for (final (flex, amount, main) in [
              (_Columns.sale, product.salePriceHt(defaultTierId), true),
              (_Columns.cost, product.lastPurchasePriceHt, false),
            ])
              Expanded(
                flex: flex,
                child: Text(
                  amount == null ? '—' : formatDA(amount),
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // Le prix de VENTE est celui qu'on cherche : en avant.
                  style: (main ? AmpereType.bodyStrong : AmpereType.bodyDesktop)
                      .copyWith(
                        color: amount == null
                            ? colors.ink3
                            : main
                            ? colors.accentHi
                            : colors.ink2,
                        fontFeatures: AmpereType.tabular,
                      ),
                ),
              ),
            const SizedBox(width: 16),
            Expanded(
              flex: _Columns.status,
              child: Align(
                alignment: Alignment.centerLeft,
                child: !product.isActive
                    ? const AmpereBadge(
                        label: 'Inactif',
                        tone: StatusTone.neutral,
                      )
                    : stock == null
                    ? const Text('—')
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StockStatusBadge(
                            product: product,
                            stock: stock![product.id],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'seuil ${formatQuantity(product.minThreshold)} '
                            '${product.unit.short}',
                            style: AmpereType.metaDesktop.copyWith(
                              color: colors.ink3,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            if (onEdit != null || onDelete != null || onLabel != null)
              SizedBox(
                width: _actionsWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  // En mode sélection, la ligne coche : pas d'action isolée.
                  child: selected != null
                      ? null
                      : ProductRowActions(
                          product: product,
                          onEdit: onEdit,
                          onDelete: onDelete,
                          onLabel: onLabel,
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
