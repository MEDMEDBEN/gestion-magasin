import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'purchases_models.dart';

/// Accès réseau des commandes fournisseurs. Aucune règle ici : le serveur fige
/// les prix et la TVA, calcule les totaux et contrôle les transitions.
class PurchasesApi {
  PurchasesApi(this._dio);

  final Dio _dio;

  Future<PurchaseOrderPage> list({int limit = 200}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/purchase-orders',
        queryParameters: {'limit': limit},
      );
      return PurchaseOrderPage.fromJson(response.data!);
    });
  }

  Future<PurchaseOrder> create(Map<String, Object?> fields) =>
      _send('POST', '/purchase-orders', fields);

  Future<PurchaseOrder> update(String id, Map<String, Object?> fields) =>
      _send('PATCH', '/purchase-orders/$id', fields);

  Future<PurchaseOrder> confirm(String id) =>
      _send('POST', '/purchase-orders/$id/confirm', null);

  Future<PurchaseOrder> cancel(String id) =>
      _send('POST', '/purchase-orders/$id/cancel', null);

  Future<PurchaseOrder> _send(
    String method,
    String path,
    Map<String, Object?>? fields,
  ) {
    return guardApi(() async {
      final response = await _dio.request<Map<String, dynamic>>(
        path,
        data: fields,
        options: Options(method: method),
      );
      return PurchaseOrder.fromJson(response.data!);
    });
  }
}

final purchasesApiProvider = Provider<PurchasesApi>(
  (ref) => PurchasesApi(ref.watch(dioClientProvider).dio),
);
