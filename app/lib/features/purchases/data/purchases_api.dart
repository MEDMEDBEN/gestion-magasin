import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/file_export.dart';
import '../../../core/providers.dart';
import 'purchases_models.dart';

/// Accès réseau des commandes fournisseurs. Aucune règle ici : le serveur fige
/// les prix et la TVA, calcule les totaux et contrôle les transitions.
class PurchasesApi {
  PurchasesApi(this._dio);

  final Dio _dio;

  Future<PurchaseOrderPage> list({int limit = 200, String? supplierId}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/purchase-orders',
        queryParameters: {'limit': limit, 'supplierId': ?supplierId},
      );
      return PurchaseOrderPage.fromJson(response.data!);
    });
  }

  Future<PurchaseOrder> create(Map<String, Object?> fields) =>
      _send('POST', '/purchase-orders', fields);

  Future<PurchaseOrder> update(String id, Map<String, Object?> fields) =>
      _send('PATCH', '/purchase-orders/$id', fields);

  Future<PurchaseOrder> confirm(String id, DateTime expectedUpdatedAt) => _send(
    'POST',
    '/purchase-orders/$id/confirm',
    {'expectedUpdatedAt': expectedUpdatedAt.toUtc().toIso8601String()},
  );

  Future<PurchaseOrder> cancel(String id) =>
      _send('POST', '/purchase-orders/$id/cancel', null);

  Future<PurchaseOrder> close(String id, String reason) =>
      _send('POST', '/purchase-orders/$id/close', {'reason': reason});

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

  /// Commandes fournisseurs des 12 derniers mois.
  Future<ExportedFile> exportOrders(ExportFormat format) {
    final window = recentWindow(365);
    return fetchExport(
      _dio,
      '/purchase-orders/export',
      format,
      query: {'from': window.from, 'to': window.to},
    );
  }

  /// PDF rendu serveur, pour l'impression / le partage (garde du détail).
  Future<Uint8List> document(String id) async {
    final response = await guardBytes(
      () => _dio.get<List<int>>(
        '/purchase-orders/$id/pdf',
        options: Options(responseType: ResponseType.bytes),
      ),
    );
    return Uint8List.fromList(response.data!);
  }
}

final purchasesApiProvider = Provider<PurchasesApi>(
  (ref) => PurchasesApi(ref.watch(dioClientProvider).dio),
);
