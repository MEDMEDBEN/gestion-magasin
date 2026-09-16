import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
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

  /// `paymentId` stable : un renvoi après coupure ne paie pas deux fois.
  Future<SupplierPayment> pay(
    String supplierId,
    int amount, {
    required bool fromCash,
    required String paymentId,
  }) async {
    final payment = await _api.pay({
      'id': paymentId,
      'supplierId': supplierId,
      'amount': amount,
      'fromCash': fromCash,
      if (!fromCash) 'method': 'VIREMENT',
    });
    _ref.invalidate(supplierSearchProvider);
    return payment;
  }
}

final suppliersActionsProvider = Provider(SuppliersActions.new);
