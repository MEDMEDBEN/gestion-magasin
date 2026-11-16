import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../ui/theme/ampere_colors.dart';
import '../data/catalog_models.dart';
import 'price_history.dart';

/// Boutons « Modifier » et « Supprimer » d'une ligne du catalogue (demande
/// MEDMEDBEN du 2026-10-05). Supprimer RETIRE le produit du catalogue (il est
/// désactivé) : ses ventes, achats et mouvements restent dans l'historique.
class ProductRowActions extends ConsumerWidget {
  const ProductRowActions({
    super.key,
    required this.product,
    this.onEdit,
    this.onDelete,
    this.onLabel,
  });

  final Product product;

  /// Étiquette de CE produit (2026-10-05) ; `null` sans le droit.
  final void Function(Product product)? onLabel;
  final void Function(Product product)? onEdit;
  final void Function(Product product)? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    void history(Product p) => showProductPriceHistory(context, ref, p);
    // Téléphone (2026-10-29) : un seul « ⋯ » au lieu de trois icônes.
    if (MediaQuery.sizeOf(context).width < 600) {
      final items = [
        ('Historique des prix', LucideIcons.history, colors.ink2, history),
        if (onLabel != null && product.isActive)
          ('Étiquette', LucideIcons.tag, colors.ink2, onLabel!),
        if (onEdit != null)
          ('Modifier', LucideIcons.pencil, colors.ink2, onEdit!),
        if (onDelete != null && product.isActive)
          ('Supprimer', LucideIcons.trash2, colors.error, onDelete!),
      ];
      return PopupMenuButton<int>(
        tooltip: 'Actions du produit',
        icon: Icon(LucideIcons.ellipsisVertical, size: 18, color: colors.ink2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onSelected: (i) => items[i].$4(product),
        itemBuilder: (_) => [
          for (final (i, (label, icon, color, _)) in items.indexed)
            PopupMenuItem(
              value: i,
              child: Row(
                children: [
                  Icon(icon, size: 17, color: color),
                  const SizedBox(width: 10),
                  Flexible(child: Text(label)),
                ],
              ),
            ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Achat et vente, d'un geste (2026-11-16).
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Historique des prix',
          icon: Icon(LucideIcons.history, size: 17, color: colors.ink2),
          onPressed: () => history(product),
        ),
        if (onLabel != null && product.isActive)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Étiquette',
            icon: Icon(LucideIcons.tag, size: 17, color: colors.ink2),
            onPressed: () => onLabel!(product),
          ),
        if (onEdit != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Modifier',
            icon: Icon(LucideIcons.pencil, size: 17, color: colors.ink2),
            onPressed: () => onEdit!(product),
          ),
        if (onDelete != null && product.isActive)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Supprimer',
            icon: Icon(LucideIcons.trash2, size: 17, color: colors.error),
            onPressed: () => onDelete!(product),
          ),
      ],
    );
  }
}
