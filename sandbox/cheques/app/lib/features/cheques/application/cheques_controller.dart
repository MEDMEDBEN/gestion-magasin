import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/mutation_keys.dart';
import '../../../core/providers.dart';
import '../data/cheques_api.dart';

/// Filtre du portefeuille ; « en portefeuille » par défaut (ce qu'il reste à
/// remettre en banque).
class ChequeFilter extends Notifier<ChequeStatus?> {
  @override
  ChequeStatus? build() => ChequeStatus.inWallet;

  void set(ChequeStatus? status) => state = status;
}

final chequeFilterProvider = NotifierProvider<ChequeFilter, ChequeStatus?>(
  ChequeFilter.new,
);

final chequesProvider = FutureProvider.autoDispose<List<Cheque>>((ref) async {
  ref.watch(currentUserIdProvider);
  return ref
      .watch(chequesApiProvider)
      .list(status: ref.watch(chequeFilterProvider));
});

/// Décision de l'ADMIN. Mutation d'argent (un rejet rend la dette) : clé
/// d'intention stable, un nouvel essai ne contre-passe jamais deux fois.
class ChequesActions {
  ChequesActions(this._ref);

  final Ref _ref;

  Future<Cheque> decide(
    Cheque cheque,
    ChequeStatus status, {
    String? reason,
  }) async {
    final done = await runMoneyMutation(
      _ref,
      'cheque:${cheque.id}:${status.wire}',
      (key) => _ref
          .read(chequesApiProvider)
          .decide(cheque, status, clientMutationId: key, reason: reason),
    );
    _ref.invalidate(chequesProvider);
    return done;
  }
}

final chequesActionsProvider = Provider(ChequesActions.new);
