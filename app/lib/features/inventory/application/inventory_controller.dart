import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/mutation_keys.dart';
import '../../../data/local/document_cache.dart';
import '../../../data/local/offline_documents.dart';
import '../../../core/quantity.dart';
import '../../stock/application/stock_controller.dart';
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';

/// Inventaires lus EN LIGNE : un comptage périmé ferait ajuster du stock sur
/// une photo fausse. Liés au compte connecté (poste partagé).
final inventoriesProvider = FutureProvider.autoDispose<CachedList<Inventory>>(
  (ref) => onlineOrCached(
    ref,
    DocumentKind.inventory,
    fetch: () async => (await ref.watch(inventoryApiProvider).list()).data,
    toJson: (i) => i.toJson(),
    fromJson: Inventory.fromJson,
  ),
);

/// Écritures de l'inventaire — toujours validées par le serveur.
class InventoryActions {
  InventoryActions(this._ref);

  final Ref _ref;

  InventoryApi get _api => _ref.read(inventoryApiProvider);

  /// Un inventaire relancé deux fois figerait deux fois le théorique : il porte
  /// la clé STABLE de son intention (`core/mutation_keys.dart`).
  Future<Inventory> start({
    required String intent,
    required String locationId,
    required InventoryType type,
    List<String>? productIds,
    String? zone,
    String? note,
  }) async {
    final inventory = await runMoneyMutation(
      _ref,
      intent,
      (clientMutationId) => _api.create({
        'clientMutationId': clientMutationId,
        'locationId': locationId,
        'type': type == InventoryType.full ? 'COMPLET' : 'TOURNANT',
        'zone': ?zone,
        'note': ?note,
        'productIds': ?productIds,
      }),
    );
    _ref.invalidate(inventoriesProvider);
    return inventory;
  }

  /// `done: false` sauvegarde un comptage en cours (reprise plus tard).
  /// Aucun stock ne bouge ici.
  Future<Inventory> count(
    String id,
    Map<String, Quantity> countedByProduct, {
    bool done = false,
  }) => _refresh(
    _api.count(id, {
      'done': done,
      'lines': [
        for (final entry in countedByProduct.entries)
          {
            'productId': entry.key,
            'countedQuantity': quantityToJson(entry.value),
          },
      ],
    }),
  );

  /// Seule étape qui touche le stock, et réservée à l'administrateur.
  Future<Inventory> validate(String id) =>
      _refresh(_api.validate(id), stockMoved: true);

  Future<Inventory> _refresh(
    Future<Inventory> call, {
    bool stockMoved = false,
  }) async {
    final inventory = await call;
    _ref.invalidate(inventoriesProvider);
    if (stockMoved) _ref.invalidate(stockByProductProvider);
    return inventory;
  }
}

final inventoryActionsProvider = Provider(InventoryActions.new);
