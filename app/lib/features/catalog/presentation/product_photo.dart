import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../application/catalog_controller.dart';
import '../data/catalog_models.dart';

/// Vignette d'un produit : sa photo si elle existe (chargée à la demande),
/// sinon une pastille neutre. Même rendu partout (liste, tableau, fiche).
class ProductThumbnail extends ConsumerWidget {
  const ProductThumbnail({super.key, required this.product, this.size = 40});

  final Product product;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final key = product.imageKey;
    final bytes = key == null
        ? null
        : ref
              .watch(
                productImageProvider((productId: product.id, imageKey: key)),
              )
              .value;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AmpereGeometry.iconChipRadius),
      child: Container(
        width: size,
        height: size,
        color: colors.surface2,
        child: bytes == null
            ? Icon(LucideIcons.package, size: size * 0.45, color: colors.ink3)
            : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
      ),
    );
  }
}
