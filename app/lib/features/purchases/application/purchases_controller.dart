import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../data/purchases_api.dart';
import '../data/purchases_models.dart';

/// Commandes lues EN LIGNE, liées au compte connecté (poste partagé).
final purchaseOrdersProvider = FutureProvider.autoDispose<List<PurchaseOrder>>((
  ref,
) async {
  ref.watch(currentUserIdProvider);
  return (await ref.watch(purchasesApiProvider).list()).data;
});

/// Ligne saisie dans le formulaire (avant envoi au serveur).
typedef PurchaseLineDraft = ({
  String productId,
  Quantity quantity,
  int unitPriceHt,
});

/// Écritures des commandes — toujours validées par le serveur.
class PurchasesActions {
  PurchasesActions(this._ref);

  final Ref _ref;

  PurchasesApi get _api => _ref.read(purchasesApiProvider);

  /// `id` : UUID stable du formulaire, un renvoi après coupure ne crée pas de
  /// seconde commande.
  Future<PurchaseOrder> save({
    required String id,
    required bool isNew,
    required String supplierId,
    required List<PurchaseLineDraft> lines,
    String? note,
  }) async {
    final payload = [
      for (final l in lines)
        {
          'productId': l.productId,
          'orderedQuantity': quantityToJson(l.quantity),
          'unitPriceHt': l.unitPriceHt,
        },
    ];
    final order = isNew
        ? await _api.create({
            'id': id,
            'supplierId': supplierId,
            'lines': payload,
            'note': ?note,
          })
        : await _api.update(id, {'lines': payload, 'note': note});
    _ref.invalidate(purchaseOrdersProvider);
    return order;
  }

  Future<PurchaseOrder> markOrdered(String id) =>
      _refresh(_api.update(id, {'status': 'COMMANDEE'}));

  /// Confirme LA version affichée (`order.updatedAt`) ; modifiée entre-temps → 409.
  Future<PurchaseOrder> confirm(PurchaseOrder order) =>
      _refresh(_api.confirm(order.id, order.updatedAt));

  Future<PurchaseOrder> cancel(String id) => _refresh(_api.cancel(id));

  /// Reliquat abandonné : la commande sort des en-cours, ce qui est reçu reste reçu.
  Future<PurchaseOrder> close(String id, String reason) =>
      _refresh(_api.close(id, reason));

  Future<PurchaseOrder> _refresh(Future<PurchaseOrder> call) async {
    final order = await call;
    _ref.invalidate(purchaseOrdersProvider);
    return order;
  }
}

final purchasesActionsProvider = Provider(PurchasesActions.new);
