import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/mutation_keys.dart';
import '../../../core/providers.dart';
import '../../payments/data/payment_models.dart';
import '../data/suppliers_api.dart';
import '../data/suppliers_models.dart';

/// Fournisseurs lus EN LIGNE (pas de cache local : la dette doit être juste,
/// et le vendeur n'y a de toute façon aucun accès).
final supplierSearchProvider = FutureProvider.autoDispose
    .family<List<Supplier>, String>((ref, query) async {
      // Lié au compte : au changement d'utilisateur, la liste et les dettes
      // du précédent ne restent pas affichées.
      ref.watch(currentUserIdProvider);
      final page = await ref
          .watch(suppliersApiProvider)
          .list(query: query.isEmpty ? null : query);
      return page.data;
    });

/// Écritures fournisseurs — toutes validées par le serveur (admin uniquement).
class SuppliersActions {
  SuppliersActions(this._ref);

  final Ref _ref;

  SuppliersApi get _api => _ref.read(suppliersApiProvider);

  Future<Supplier> save({
    String? id,
    required String name,
    String? phone,
    String? contactName,
    String? address,
    required int openingBalance,
  }) async {
    final fields = <String, Object?>{
      'name': name,
      'phone': phone,
      'contactName': contactName,
      'address': address,
      'openingBalance': openingBalance,
    };
    final supplier = id == null
        ? await _api.create(fields)
        : await _api.update(id, fields);
    _ref.invalidate(supplierSearchProvider);
    return supplier;
  }

  /// Clé d'idempotence gardée par intention (`core/mutation_keys.dart`) : un
  /// nouvel essai après coupure ou délai dépassé ne paie jamais deux fois.
  Future<SupplierPayment> pay(
    String supplierId,
    int amount, {
    required bool fromCash,
  }) async {
    final payment = await runMoneyMutation(
      _ref,
      'supplier-payment:$supplierId',
      (key) => _api.pay({
        'clientMutationId': key,
        'supplierId': supplierId,
        'amount': amount,
        'fromCash': fromCash,
        if (!fromCash) 'method': 'VIREMENT',
      }),
    );
    _ref.invalidate(supplierSearchProvider);
    return payment;
  }
}

extension SupplierPaymentsActions on SuppliersActions {
  Future<List<PaymentHistoryItem>> payments(String supplierId) async =>
      (await _api.payments(supplierId)).data;

  /// Contre-passation (ADMIN) : écriture opposée, la dette revient.
  Future<void> reversePayment(String paymentId, String reason) async {
    await runMoneyMutation(
      _ref,
      'reverse:supplier-payment:$paymentId',
      (key) =>
          _api.reversePayment(paymentId, clientMutationId: key, reason: reason),
    );
    _ref.invalidate(supplierSearchProvider);
  }
}

final suppliersActionsProvider = Provider(SuppliersActions.new);
