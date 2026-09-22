import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../sales/application/sales_controller.dart';
import '../../stock/application/stock_controller.dart';

/// Longueur maximale d'un code-barres produit (EAN-13, Code128…) : au-delà,
/// ce n'est pas un code produit — on ne le réaffiche pas tel quel.
const _maxBarcodeLength = 64;

/// Code lisible dans un message, borné et sans caractères de mise en forme
/// (un QR peut porter 4 ko de texte, y compris de quoi renverser l'affichage).
String readableBarcode(String raw) {
  final clean = raw.trim().replaceAll(RegExp(r'[^ -~]'), '');
  return clean.length <= _maxBarcodeLength
      ? clean
      : '${clean.substring(0, _maxBarcodeLength)}…';
}

/// Produit du catalogue LOCAL portant ce code-barres, ou `null`.
/// Le catalogue est en local : un scan répond donc même sans réseau.
Product? productForBarcode(List<Product> products, String barcode) {
  final code = barcode.trim();
  if (code.isEmpty || code.length > _maxBarcodeLength) return null;
  return products.where((p) => p.barcode == code).firstOrNull;
}

/// Ce que le scan montre (spec §27) : le produit, son prix, ses stocks magasin
/// et dépôt avec l'emplacement, et les actions permises au compte.
///
/// Les stocks viennent du SERVEUR (ils changent à chaque vente) : hors ligne,
/// ils sont annoncés indisponibles plutôt que devinés.
class ScannedProductSheet extends ConsumerWidget {
  const ScannedProductSheet({
    super.key,
    required this.barcode,
    required this.user,
    this.onAddedToCart,
  });

  final String barcode;
  final AuthUser user;
  final VoidCallback? onAddedToCart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final products = ref.watch(activeProductsProvider).value ?? const [];
    final product = productForBarcode(products, barcode);
    if (product == null) {
      return ScreenStateView(
        status: ScreenStatus.empty,
        title: 'Code inconnu',
        message:
            'Aucun produit actif ne porte le code ${readableBarcode(barcode)}. '
            'Vérifiez le catalogue, ou créez le produit côté administration.',
      );
    }

    final canSell = user.hasRole('ADMIN') || user.hasRole('VENDEUR');
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(product.name, style: AmpereType.h4.copyWith(color: colors.ink)),
          Text(
            '${product.sku} · ${readableBarcode(barcode)}',
            style: AmpereType.mono.copyWith(color: colors.ink3),
          ),
          // Mêmes miroirs de guards que le Catalogue : l'UI n'affiche que ce
          // que le serveur accepterait de montrer (CLAUDE.md règle 1).
          if (user.can('price.read')) ...[
            const SizedBox(height: 12),
            _PriceLine(product: product),
          ],
          if (user.can('stock.read.store')) ...[
            const SizedBox(height: 12),
            _StockLines(product: product),
          ],
          const SizedBox(height: 16),
          if (canSell && user.can('sale.create'))
            SizedBox(
              height: AmpereGeometry.touchPrimary,
              child: FilledButton.icon(
                onPressed: () {
                  ref.read(cartProvider.notifier).add(product);
                  onAddedToCart?.call();
                },
                icon: const Icon(LucideIcons.shoppingCart, size: 18),
                label: const Text('Ajouter au panier'),
              ),
            ),
        ],
      ),
    );
  }
}

class _PriceLine extends ConsumerWidget {
  const _PriceLine({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final tiers = ref.watch(priceTiersProvider).value ?? const <PriceTier>[];
    // MÊME tarif que la vente : celui du client déjà choisi au panier, sinon le
    // tarif par défaut — sinon le scan annonce un prix et la ligne en facture
    // un autre (règle 13).
    final tierId =
        ref.watch(cartProvider).customer?.priceTierId ??
        tiers.where((t) => t.isDefault).firstOrNull?.id;
    final price = product.prices
        .where((p) => p.priceTierId == tierId)
        .firstOrNull;
    return Text(
      price == null
          ? 'Prix non fixé pour le tarif appliqué'
          : '${formatDA(price.priceHt)} HT',
      style: AmpereType.bodyStrong.copyWith(color: colors.ink),
    );
  }
}

class _StockLines extends ConsumerWidget {
  const _StockLines({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final locations = ref.watch(locationsProvider).value ?? const [];
    final stocks = ref.watch(productStockProvider(product.id));
    return stocks.when(
      loading: () => const LinearProgressIndicator(minHeight: 2),
      // Le stock vient du serveur : sans réseau, on le DIT, on ne l'invente
      // pas — et un refus de DROIT ne se déguise pas en panne de réseau.
      error: (error, _) => Text(
        error is ApiException && !error.isOffline
            ? 'Stock non accessible : ${error.userMessage}'
            : 'Stock indisponible hors ligne — reconnectez-vous pour le voir.',
        style: AmpereType.meta.copyWith(color: colors.ink2),
      ),
      data: (stock) {
        if (stock.levels.isEmpty) {
          return Text(
            'Aucun stock enregistré pour ce produit.',
            style: AmpereType.meta.copyWith(color: colors.ink2),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final level in stock.levels)
              Text(
                '${locations.where((l) => l.id == level.locationId).firstOrNull?.name ?? 'Emplacement'} : '
                '${formatQuantity(level.quantity)} ${product.unit.short}'
                ' (dispo ${formatQuantity(level.availableQuantity)})',
                style: AmpereType.body.copyWith(color: colors.ink),
              ),
          ],
        );
      },
    );
  }
}
