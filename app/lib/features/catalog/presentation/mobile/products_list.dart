import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../ui/theme/ampere_colors.dart';
import '../../../../ui/theme/ampere_typography.dart';
import '../../../../ui/widgets/ampere_controls.dart';
import '../../../../ui/widgets/screen_state.dart';
import '../../../stock/application/stock_controller.dart';
import '../../../stock/presentation/stock_status.dart';
import '../../data/catalog_models.dart';

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
    this.stock,
  });

  /// Stock par produit — `null` si non chargé ou non autorisé.
  final Map<String, ProductStock>? stock;
  final List<Product> products;
  final Map<String, String> categoryNames;
  final void Function(Product product) onTap;
  final Future<void> Function() onRefresh;

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
          onTap: () => onTap(products[i]),
        ),
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
  });

  final Product product;
  final String? category;
  final VoidCallback onTap;
  final Map<String, ProductStock>? stock;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return AmpereTappable(
      onTap: onTap,
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
            AmpereIconChip(
              icon: LucideIcons.package,
              tone: product.isActive ? StatusTone.info : StatusTone.neutral,
            ),
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
                    '${product.sku} · ${product.barcode}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.mono.copyWith(color: colors.ink3),
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
          ],
        ),
      ),
    );
  }
}
