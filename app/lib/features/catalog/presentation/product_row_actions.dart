import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../ui/theme/ampere_colors.dart';
import '../data/catalog_models.dart';

/// Boutons « Modifier » et « Supprimer » d'une ligne du catalogue (demande
/// MEDMEDBEN du 2026-10-05). Supprimer RETIRE le produit du catalogue (il est
/// désactivé) : ses ventes, achats et mouvements restent dans l'historique.
class ProductRowActions extends StatelessWidget {
  const ProductRowActions({
    super.key,
    required this.product,
    this.onEdit,
    this.onDelete,
  });

  final Product product;
  final void Function(Product product)? onEdit;
  final void Function(Product product)? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onEdit != null)
          IconButton(
            tooltip: 'Modifier',
            icon: Icon(LucideIcons.pencil, size: 17, color: colors.ink2),
            onPressed: () => onEdit!(product),
          ),
        if (onDelete != null && product.isActive)
          IconButton(
            tooltip: 'Supprimer',
            icon: Icon(LucideIcons.trash2, size: 17, color: colors.error),
            onPressed: () => onDelete!(product),
          ),
      ],
    );
  }
}
