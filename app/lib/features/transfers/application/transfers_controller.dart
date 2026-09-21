import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/mutation_keys.dart';
import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../stock/application/stock_controller.dart';
import '../data/transfers_api.dart';
import '../data/transfers_models.dart';

/// Transferts lus EN LIGNE : un état de transfert périmé ferait préparer ou
/// réceptionner deux fois. Liés au compte connecté (poste partagé).
final transfersProvider = FutureProvider.autoDispose<List<Transfer>>((
  ref,
) async {
  ref.watch(currentUserIdProvider);
  return (await ref.watch(transfersApiProvider).list()).data;
});

/// Ligne saisie dans le formulaire de demande (avant envoi au serveur).
typedef TransferLineDraft = ({String productId, Quantity quantity});

/// Écritures des transferts — toujours validées par le serveur.
class TransfersActions {
  TransfersActions(this._ref);

  final Ref _ref;

  TransfersApi get _api => _ref.read(transfersApiProvider);

  /// Une demande renvoyée deux fois ne doit pas devenir deux demandes : elle
  /// porte la clé STABLE de son intention, comme les mutations d'argent
  /// (`core/mutation_keys.dart`). Aucun stock ne bouge ici.
  Future<Transfer> request({
    required String intent,
    required List<TransferLineDraft> lines,
    TransferPriority priority = TransferPriority.normal,
    String? comment,
  }) async {
    final transfer = await runMoneyMutation(
      _ref,
      intent,
      (clientMutationId) => _api.create({
        'clientMutationId': clientMutationId,
        'priority': _wire(priority),
        'comment': ?comment,
        'lines': [
          for (final l in lines)
            {'productId': l.productId, 'quantity': quantityToJson(l.quantity)},
        ],
      }),
    );
    _ref.invalidate(transfersProvider);
    return transfer;
  }

  Future<Transfer> accept(String id) => _refresh(_api.accept(id));

  /// `done: false` sauvegarde une préparation en cours (reprise plus tard).
  Future<Transfer> prepare(
    String id,
    Map<String, Quantity> preparedByProduct, {
    bool done = true,
  }) => _refresh(
    _api.prepare(id, {
      'done': done,
      'lines': [
        for (final entry in preparedByProduct.entries)
          {
            'productId': entry.key,
            'preparedQuantity': quantityToJson(entry.value),
          },
      ],
    }),
  );

  /// Le stock quitte le dépôt pour le transit : les niveaux changent.
  Future<Transfer> ship(String id) => _refresh(_api.ship(id), stockMoved: true);

  /// Le stock entre au magasin ; l'écart éventuel retourne au dépôt.
  Future<Transfer> receive(String id, Map<String, Quantity> receivedByProduct) =>
      _refresh(
        _api.receive(id, {
          'lines': [
            for (final entry in receivedByProduct.entries)
              {
                'productId': entry.key,
                'receivedQuantity': quantityToJson(entry.value),
              },
          ],
        }),
        stockMoved: true,
      );

  Future<Transfer> cancel(String id, {required bool refuse}) =>
      _refresh(_api.cancel(id, refuse ? 'REFUSEE' : 'ANNULEE'));

  Future<Transfer> _refresh(
    Future<Transfer> call, {
    bool stockMoved = false,
  }) async {
    final transfer = await call;
    _ref.invalidate(transfersProvider);
    if (stockMoved) _ref.invalidate(stockByProductProvider);
    return transfer;
  }

  static String _wire(TransferPriority priority) => switch (priority) {
    TransferPriority.low => 'BASSE',
    TransferPriority.normal => 'NORMALE',
    TransferPriority.high => 'HAUTE',
    TransferPriority.urgent => 'URGENTE',
  };
}

final transfersActionsProvider = Provider(TransfersActions.new);
