import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/money.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../catalog/presentation/product_photo.dart';
import '../../stock/application/stock_controller.dart';

/// Fiche « infos » d'un produit, ouverte depuis sa tuile en Vente (demande
/// MEDMEDBEN du 2026-11-10) : photo, prix de vente et d'achat, stock magasin et
/// dépôt, code-barres, fournisseur. `onAdd` : bouton « Ajouter au panier ».
class ProductInfoPanel extends ConsumerWidget {
  const ProductInfoPanel({super.key, required this.product, this.onAdd});

  final Product product;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final tiers = ref.watch(priceTiersProvider).value ?? const <PriceTier>[];
    final defaultTier = tiers.where((t) => t.isDefault).firstOrNull?.id;
    final price = product.salePriceHt(defaultTier);
    final cost = product.lastPurchasePriceHt;
    final category = (ref.watch(categoriesProvider).value ?? const [])
        .where((c) => c.id == product.categoryId)
        .firstOrNull
        ?.name;
    final locations = ref.watch(locationsProvider).value ?? const [];
    final stock = ref.watch(stockByProductProvider);
    final unit = product.unit.short;
    final place = locations
        .where((l) => l.id == product.storageLocationId)
        .firstOrNull
        ?.name;

    Widget figure(String label, String value, Color tone, IconData icon) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tone.withValues(alpha: 0.28)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 14, color: tone),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AmpereType.meta.copyWith(color: colors.ink3),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: AmpereType.numeric.copyWith(color: colors.ink),
                  ),
                ),
              ],
            ),
          ),
        );

    Widget row(IconData icon, String label, String value, {Widget? trailing}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              Icon(icon, size: 16, color: colors.ink3),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                child: Text(
                  label,
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
              ),
              Expanded(
                child: Text(
                  value,
                  style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                ),
              ),
              ?trailing,
            ],
          ),
        );

    // Stock par lieu (magasin, dépôt), lu en ligne ; hors ligne : inconnu.
    final levels = stock.value?[product.id];
    final stockRows = [
      for (final l in locations.where(
        (l) => l.isActive && (l.type == 'MAGASIN' || l.type == 'DEPOT'),
      ))
        row(
          l.type == 'MAGASIN' ? LucideIcons.store : LucideIcons.warehouse,
          'Stock ${l.name}',
          levels == null && stock.value == null
              ? (stock.isLoading ? '…' : 'Hors ligne')
              : '${formatQuantity(levels?.at(l.id) ?? Quantity.zero)} $unit',
        ),
    ];

    return FormPanelFrame(
      formKey: GlobalKey<FormState>(),
      title: 'Infos produit',
      submitLabel: 'Ajouter au panier',
      onSubmit: onAdd == null
          ? null
          : () {
              Navigator.of(context).pop();
              onAdd!();
            },
      children: [
        Center(child: ProductThumbnail(product: product, size: 200)),
        const SizedBox(height: 14),
        Text(
          product.name,
          textAlign: TextAlign.center,
          style: AmpereType.h4.copyWith(color: colors.ink),
        ),
        const SizedBox(height: 4),
        Text(
          [?product.brand, ?category, 'Réf. ${product.sku}'].join(' · '),
          textAlign: TextAlign.center,
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            figure(
              'Prix de vente',
              price == null ? 'Non fixé' : '${formatDA(price)} / $unit',
              colors.accent,
              LucideIcons.tag,
            ),
            const SizedBox(width: 10),
            figure(
              'Prix d’achat',
              cost == null ? 'Inconnu' : '${formatDA(cost)} / $unit',
              colors.warn,
              LucideIcons.shoppingBag,
            ),
          ],
        ),
        if (price != null && cost != null) ...[
          const SizedBox(height: 8),
          Text(
            'Marge : ${formatDA(price - cost)} par $unit',
            textAlign: TextAlign.center,
            style: AmpereType.bodyStrong.copyWith(
              color: price >= cost ? colors.ok : colors.error,
            ),
          ),
        ],
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: colors.surface2,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              ...stockRows,
              if (place != null) row(LucideIcons.mapPin, 'Emplacement', place),
              row(
                LucideIcons.triangleAlert,
                'Seuil d’alerte',
                '${formatQuantity(product.minThreshold)} $unit',
              ),
              row(
                LucideIcons.barcode,
                'Code-barres',
                product.barcode,
                trailing: IconButton(
                  tooltip: 'Copier le code',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(LucideIcons.copy, color: colors.ink2),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: product.barcode)),
                ),
              ),
              row(
                LucideIcons.truck,
                'Fournisseur',
                product.mainSupplierName ?? 'Non renseigné',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
