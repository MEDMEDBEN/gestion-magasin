import 'dart:typed_data';

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
    final photo = key == null
        ? null
        : ref.watch(
            productImageProvider((productId: product.id, imageKey: key)),
          );
    final bytes = photo?.value;
    // Photo attendue mais illisible (réseau, fichier perdu au serveur) : on
    // le MONTRE, au lieu d'une vignette vide qui laisse croire à un oubli.
    final failed = photo != null && photo.hasError && bytes == null;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AmpereGeometry.iconChipRadius),
      child: Container(
        width: size,
        height: size,
        color: colors.surface2,
        child: bytes != null
            ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
            : failed
            ? Tooltip(
                message: 'Photo indisponible',
                child: Icon(
                  LucideIcons.imageOff,
                  size: size * 0.45,
                  color: colors.warn,
                ),
              )
            : Icon(LucideIcons.package, size: size * 0.45, color: colors.ink3),
      ),
    );
  }
}

/// Photo en GRAND (demande MEDMEDBEN du 2026-11-23) : plein écran sombre,
/// zoom à la molette / au pincement (jusqu'à ×5), glisser pour se déplacer.
/// Échap, la croix ou un clic hors de la photo ferment.
Future<void> showPhotoViewer(
  BuildContext context, {
  required Uint8List bytes,
  required String title,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.88),
    builder: (context) => Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: InteractiveViewer(
                key: const ValueKey('photo-zoom'),
                minScale: 1,
                maxScale: 5,
                child: Center(
                  child: GestureDetector(
                    // Un clic SUR la photo ne ferme pas (on zoome dessus).
                    onTap: () {},
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 16,
            right: 64,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AmpereType.sectionTitle.copyWith(color: Colors.white),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              tooltip: 'Fermer',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(LucideIcons.x, color: Colors.white, size: 24),
            ),
          ),
          const Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Text(
              'Molette ou pincer pour zoomer · glisser pour déplacer',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}
