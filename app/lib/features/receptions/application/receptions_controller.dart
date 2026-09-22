import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/offline_write.dart';
import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../purchases/application/purchases_controller.dart';
import '../../suppliers/application/suppliers_controller.dart';
import '../data/receptions_api.dart';
import '../data/receptions_models.dart';

/// Réceptions d'une commande, lues EN LIGNE.
final orderReceptionsProvider = FutureProvider.autoDispose
    .family<List<Reception>, String>((ref, purchaseOrderId) async {
      ref.watch(currentUserIdProvider);
      return ref
          .watch(receptionsApiProvider)
          .list(purchaseOrderId: purchaseOrderId);
    });

/// Ligne saisie à la réception (avant envoi au serveur).
typedef ReceptionLineDraft = ({
  String productId,
  String? purchaseLineId,
  Quantity receivedQuantity,
  int unitPriceHt,
});

class ReceptionsActions {
  ReceptionsActions(this._ref);

  final Ref _ref;

  /// La réception fait entrer la marchandise ET endette le fournisseur : elle
  /// porte une clé d'idempotence stable (`intent`), comme tout mouvement
  /// d'argent. Un renvoi après coupure rend le bon déjà enregistré.
  ///
  /// Sans réseau, la réception part dans la file (même clé, même corps) : elle
  /// n'est PAS faite tant que le serveur ne l'a pas jugée (surlivraison, commande
  /// annulée entre-temps…) — `Queued`, jamais présentée comme définitive.
  Future<WriteOutcome<Reception>> receive({
    required String intent,
    String? purchaseOrderId,
    required String supplierId,
    required String locationId,
    required List<ReceptionLineDraft> lines,
    String? note,
  }) async {
    final outcome = await writeOnlineOrQueue<Reception>(
      _ref,
      intent: intent,
      operationType: 'RECEPTION',
      online: _ref.read(receptionsApiProvider).create,
      payload: (clientMutationId) => {
        'clientMutationId': clientMutationId,
        // Id généré par l'appareil (contrat §1) : la clé de l'intention.
        'id': clientMutationId,
        'purchaseOrderId': ?purchaseOrderId,
        'supplierId': supplierId,
        'locationId': locationId,
        'note': ?note,
        'lines': [
          for (final l in lines)
            {
              'productId': l.productId,
              'purchaseLineId': ?l.purchaseLineId,
              'receivedQuantity': quantityToJson(l.receivedQuantity),
              'unitPriceHt': l.unitPriceHt,
            },
        ],
      },
    );
    // Stock, avancement de la commande et dette fournisseur ont bougé.
    _ref.invalidate(purchaseOrdersProvider);
    _ref.invalidate(supplierSearchProvider);
    if (purchaseOrderId != null) {
      _ref.invalidate(orderReceptionsProvider(purchaseOrderId));
    }
    return outcome;
  }
}

final receptionsActionsProvider = Provider(ReceptionsActions.new);
