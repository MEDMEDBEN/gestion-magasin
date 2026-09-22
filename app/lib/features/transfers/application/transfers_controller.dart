import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/offline_write.dart';
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

/// Message d'une étape : faite (`Applied`), ou seulement enregistrée sur
/// l'appareil (`Queued`) — jamais présentée comme faite avant le serveur.
String transferOutcomeText(
  WriteOutcome<Transfer> outcome, {
  String Function(Transfer transfer)? done,
}) => switch (outcome) {
  Applied(value: final t) =>
    done?.call(t) ?? '${t.number} : ${t.status.label}.',
  Queued() =>
    'Enregistré sur cet appareil — en attente de synchronisation '
        '(pas encore fait).',
};

/// Écritures des transferts — validées par le serveur ; sans réseau, chaque
/// étape part dans la file (opération `TRANSFER`, champ `action`) et le
/// serveur la rejuge au sync (état du transfert, stock du dépôt, droits).
class TransfersActions {
  TransfersActions(this._ref);

  final Ref _ref;

  TransfersApi get _api => _ref.read(transfersApiProvider);

  /// Une demande renvoyée deux fois ne doit pas devenir deux demandes : elle
  /// porte la clé STABLE de son intention (`core/mutation_keys.dart`), et son
  /// id est cette clé. Aucun stock ne bouge ici.
  Future<WriteOutcome<Transfer>> request({
    required String intent,
    required List<TransferLineDraft> lines,
    TransferPriority priority = TransferPriority.normal,
    String? comment,
  }) async {
    final outcome = await writeOnlineOrQueue<Transfer>(
      _ref,
      intent: intent,
      operationType: 'TRANSFER',
      payload: (key) => {
        'action': 'REQUEST',
        'clientMutationId': key,
        'id': key,
        'priority': _wire(priority),
        'comment': ?comment,
        'lines': [
          for (final l in lines)
            {'productId': l.productId, 'quantity': quantityToJson(l.quantity)},
        ],
      },
      online: (body) => _api.create({...body}..remove('action')),
      queueOnly: await _behindQueue(),
    );
    _ref.invalidate(transfersProvider);
    return outcome;
  }

  Future<WriteOutcome<Transfer>> accept(String id) => _step('ACCEPT', id, null);

  /// `done: false` sauvegarde une préparation en cours (reprise plus tard).
  Future<WriteOutcome<Transfer>> prepare(
    String id,
    Map<String, Quantity> preparedByProduct, {
    bool done = true,
  }) => _step('PREPARE', id, {
    'done': done,
    'lines': [
      for (final entry in preparedByProduct.entries)
        {
          'productId': entry.key,
          'preparedQuantity': quantityToJson(entry.value),
        },
    ],
  });

  /// Le stock quitte le dépôt pour le transit : les niveaux changent.
  Future<WriteOutcome<Transfer>> ship(String id) =>
      _step('SHIP', id, null, stockMoved: true);

  /// Le stock entre au magasin ; l'écart éventuel retourne au dépôt.
  Future<WriteOutcome<Transfer>> receive(
    String id,
    Map<String, Quantity> receivedByProduct,
  ) => _step('RECEIVE', id, {
    'lines': [
      for (final entry in receivedByProduct.entries)
        {
          'productId': entry.key,
          'receivedQuantity': quantityToJson(entry.value),
        },
    ],
  }, stockMoved: true);

  Future<WriteOutcome<Transfer>> cancel(String id, {required bool refuse}) =>
      _step('CLOSE', id, {'status': refuse ? 'REFUSEE' : 'ANNULEE'});

  /// Une étape : en ligne (la route de l'étape, sans les champs propres à la
  /// file), sinon dans la file. Si des étapes de transfert attendent déjà
  /// (une demande faite hors ligne…), celle-ci passe DERRIÈRE elles.
  Future<WriteOutcome<Transfer>> _step(
    String action,
    String id,
    Map<String, Object?>? fields, {
    bool stockMoved = false,
  }) async {
    final outcome = await writeOnlineOrQueue<Transfer>(
      _ref,
      intent: 'transfer-${action.toLowerCase()}:$id',
      operationType: 'TRANSFER',
      payload: (key) => {
        'action': action,
        'clientMutationId': key,
        'transferId': id,
        ...?fields,
      },
      online: (_) => switch (action) {
        'ACCEPT' => _api.accept(id),
        'PREPARE' => _api.prepare(id, fields!),
        'SHIP' => _api.ship(id),
        'RECEIVE' => _api.receive(id, fields!),
        _ => _api.cancel(id, fields!['status']! as String),
      },
      queueOnly: await _behindQueue(),
    );
    _ref.invalidate(transfersProvider);
    if (stockMoved) _ref.invalidate(stockByProductProvider);
    return outcome;
  }

  Future<bool> _behindQueue() async {
    final userId = _ref.read(currentUserIdProvider);
    if (userId == null) return false;
    return await _ref
            .read(mutationQueueProvider)
            .latestPending(authorUserId: userId, operationType: 'TRANSFER') !=
        null;
  }

  static String _wire(TransferPriority priority) => switch (priority) {
    TransferPriority.low => 'BASSE',
    TransferPriority.normal => 'NORMALE',
    TransferPriority.high => 'HAUTE',
    TransferPriority.urgent => 'URGENTE',
  };
}

final transfersActionsProvider = Provider(TransfersActions.new);
