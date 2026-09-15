import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../data/stock_api.dart';
import '../data/stock_models.dart';

/// Stock total d'un produit, tous emplacements confondus (spec §6 :
/// « Magasin 20 · Dépôt 50 · Transit 10 · Total 80 »).
class ProductStock {
  const ProductStock(this.levels);

  final List<StockLevel> levels;

  Quantity get total =>
      levels.fold(Quantity.zero, (sum, level) => sum + level.quantity);
  Quantity get available =>
      levels.fold(Quantity.zero, (sum, level) => sum + level.availableQuantity);

  Quantity at(String locationId) => levels
      .where((level) => level.locationId == locationId)
      .fold(Quantity.zero, (sum, level) => sum + level.quantity);
}

/// Tout le stock, indexé par produit. Lu EN LIGNE : le stock bouge vite, un
/// chiffre périmé affiché comme vrai serait pire que « hors ligne ».
/// ponytail: toutes les pages sont chargées (un magasin + un dépôt, quelques
/// milliers de lignes) ; filtrer côté serveur par page de produits si ça grossit.
final stockByProductProvider =
    FutureProvider.autoDispose<Map<String, ProductStock>>((ref) async {
      ref.watch(currentUserIdProvider);
      final api = ref.watch(stockApiProvider);
      final levels = <StockLevel>[];
      for (var page = 1; ; page++) {
        final result = await api.levels(page: page);
        levels.addAll(result.data);
        if (!result.meta.hasMoreAfter(levels.length)) break;
      }
      final byProduct = <String, List<StockLevel>>{};
      for (final level in levels) {
        (byProduct[level.productId] ??= []).add(level);
      }
      return {
        for (final entry in byProduct.entries)
          entry.key: ProductStock(entry.value),
      };
    });

/// Les 50 derniers mouvements d'un produit (journal immuable).
final productMovementsProvider = FutureProvider.autoDispose
    .family<List<StockMovementEntry>, String>((ref, productId) async {
      ref.watch(currentUserIdProvider);
      final page = await ref
          .watch(stockApiProvider)
          .movements(productId: productId);
      return page.data;
    });

/// Déclarations de perte, filtrées par statut (`null` = toutes).
final stockLossesProvider = FutureProvider.autoDispose
    .family<List<StockLoss>, StockLossStatus?>((ref, status) async {
      ref.watch(currentUserIdProvider);
      final page = await ref.watch(stockApiProvider).losses(status: status);
      return page.data;
    });

/// Écritures du stock — toujours via le serveur, qui tient les règles. Après
/// chaque décision, les listes et niveaux concernés sont rechargés.
class StockActions {
  StockActions(this._ref);

  final Ref _ref;

  Future<StockLoss> declareLoss({
    required String productId,
    required String locationId,
    required Quantity quantity,
    String? comment,
  }) async {
    final loss = await _ref
        .read(stockApiProvider)
        .declareLoss(
          // UUID client : un renvoi après coupure ne crée pas un doublon.
          id: _ref.read(uuidProvider).v7(),
          productId: productId,
          locationId: locationId,
          quantity: quantityToJson(quantity),
          comment: comment,
        );
    _refresh();
    return loss;
  }

  Future<StockLoss> validate(String id) async {
    final loss = await _ref.read(stockApiProvider).validateLoss(id);
    _refresh();
    return loss;
  }

  Future<StockLoss> reject(String id, {String? note}) async {
    final loss = await _ref.read(stockApiProvider).rejectLoss(id, note: note);
    _refresh();
    return loss;
  }

  void _refresh() {
    _ref.invalidate(stockLossesProvider);
    _ref.invalidate(stockByProductProvider);
    _ref.invalidate(productMovementsProvider);
  }
}

final stockActionsProvider = Provider<StockActions>(StockActions.new);
