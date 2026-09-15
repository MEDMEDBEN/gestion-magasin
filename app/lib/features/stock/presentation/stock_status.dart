import 'package:flutter/material.dart';

import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/stock_controller.dart';

/// État du stock d'un produit, déduit des quantités et du seuil minimum.
enum StockState { inStock, low, out }

StockState stockStateOf(Quantity total, Quantity minThreshold) {
  if (total <= Quantity.zero) return StockState.out;
  if (minThreshold > Quantity.zero && total <= minThreshold) {
    return StockState.low;
  }
  return StockState.inStock;
}

/// Badge « En stock · 120 m » / « Stock faible · 4 pce » / « Rupture ».
/// Le libellé porte l'information, la couleur ne fait que la souligner (§12.4).
class StockStatusBadge extends StatelessWidget {
  const StockStatusBadge({super.key, required this.product, this.stock});

  final Product product;

  /// `null` : stock non chargé (hors ligne ou droit absent) — rien n'est affirmé.
  final ProductStock? stock;

  @override
  Widget build(BuildContext context) {
    final total = stock?.total ?? Quantity.zero;
    final quantity = '${formatQuantity(total)} ${product.unit.short}';
    final (label, tone) = switch (stockStateOf(total, product.minThreshold)) {
      StockState.inStock => ('En stock · $quantity', StatusTone.ok),
      StockState.low => ('Stock faible · $quantity', StatusTone.warn),
      StockState.out => ('Rupture', StatusTone.error),
    };
    return AmpereBadge(label: label, tone: tone);
  }
}
