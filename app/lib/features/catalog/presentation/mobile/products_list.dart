import 'package:flutter/material.dart';

import '../../../../core/money.dart';
import '../../../../ui/theme/ampere_colors.dart';
import '../../../../ui/theme/ampere_typography.dart';
import '../../../../ui/widgets/ampere_controls.dart';
import '../../../../ui/widgets/screen_state.dart';
import '../../../stock/application/stock_controller.dart';
import '../../../stock/presentation/stock_status.dart';
import '../../data/catalog_models.dart';
import '../product_row_actions.dart';
import '../product_photo.dart';

/// Liste mobile (AMPÈRE §7, §9 : aucun tableau sur mobile) — lignes tactiles
/// ≥ 56 : désignation, référence et code-barres, catégorie. Tirer pour mettre
/// le catalogue à jour.
class ProductsList extends StatelessWidget {
  const ProductsList({
    super.key,
    required this.products,
    required this.categoryNames,
    required this.onTap,
    required this.onRefresh,
    this.defaultTierId,
    this.stock,
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

  /// Stock par produit — `null` si non chargé ou non autorisé.
  final Map<String, ProductStock>? stock;
  final List<Product> products;
  final Map<String, String> categoryNames;
  final void Function(Product product) onTap;
  final Future<void> Function() onRefresh;

  /// Tarif par défaut : son prix est le « prix de vente » affiché.
  final String? defaultTierId;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(
          AmpereGeometry.screenMarginMobile,
          0,
          AmpereGeometry.screenMarginMobile,
          24,
        ),
        itemCount: products.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
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
          onToggle: onToggle == null ? null : () => onToggle!(products[i]),
        ),
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({
    this.defaultTierId,
    required this.product,
    required this.category,
    required this.onTap,
    required this.stock,
    this.onEdit,
    this.onDelete,
    this.onLabel,
    this.selected,
    this.onToggle,
  });

  final String? defaultTierId;
  final Product product;
  final String? category;
  final VoidCallback onTap;
  final Map<String, ProductStock>? stock;
  final void Function(Product product)? onEdit;
  final void Function(Product product)? onDelete;
  final void Function(Product product)? onLabel;
  final bool? selected;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return AmpereTappable(
      onTap: selected != null ? onToggle : onTap,
      borderRadius: AmpereGeometry.cardRadiusMobile,
      color: colors.surface,
      child: Container(
        constraints: const BoxConstraints(minHeight: AmpereGeometry.listRowMin),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          border: Border.all(
            color: colors.line,
            width: AmpereGeometry.borderWidth,
          ),
          borderRadius: BorderRadius.circular(AmpereGeometry.cardRadiusMobile),
        ),
        child: Row(
          children: [
            if (selected != null)
              Checkbox(value: selected, onChanged: (_) => onToggle?.call()),
            ProductThumbnail(product: product, size: 52),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.rowTitle.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [product.sku, ?product.brand].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.meta.copyWith(color: colors.ink3),
                  ),
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: _amount(product.salePriceHt(defaultTierId)),
                          style: AmpereType.bodyStrong.copyWith(
                            color: colors.accentHi,
                          ),
                        ),
                        TextSpan(
                          text:
                              '  ·  achat ${_amount(product.lastPurchasePriceHt)}',
                          style: AmpereType.meta.copyWith(color: colors.ink3),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (category != null ||
                      !product.isActive ||
                      stock != null) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (category != null)
                          AmpereBadge(
                            label: category!,
                            tone: StatusTone.neutral,
                          ),
                        if (!product.isActive)
                          const AmpereBadge(
                            label: 'Inactif',
                            tone: StatusTone.warn,
                          )
                        else if (stock != null)
                          StockStatusBadge(
                            product: product,
                            stock: stock![product.id],
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (selected == null &&
                (onEdit != null || onDelete != null || onLabel != null))
              ProductRowActions(
                product: product,
                onEdit: onEdit,
                onDelete: onDelete,
                onLabel: onLabel,
              ),
          ],
        ),
      ),
    );
  }
}

String _amount(int? centimes) => centimes == null ? '—' : formatDA(centimes);
