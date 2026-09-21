import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'inventory_models.dart';

/// Accès réseau de l'inventaire. Aucune règle ici : le serveur fige le
/// théorique, calcule les écarts et n'ajuste le stock qu'à la validation.
class InventoryApi {
  InventoryApi(this._dio);

  final Dio _dio;

  Future<InventoryPage> list({String? status, int limit = 100}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/inventories',
        queryParameters: {'limit': limit, 'status': ?status},
      );
      return InventoryPage.fromJson(response.data!);
    });
  }

  Future<Inventory> create(Map<String, Object?> fields) =>
      _send('/inventories', fields);

  Future<Inventory> count(String id, Map<String, Object?> fields) =>
      _send('/inventories/$id/count', fields);

  Future<Inventory> validate(String id) =>
      _send('/inventories/$id/validate', null);

  Future<Inventory> _send(String path, Map<String, Object?>? fields) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        path,
        data: fields,
      );
      return Inventory.fromJson(response.data!);
    });
  }
}

final inventoryApiProvider = Provider<InventoryApi>(
  (ref) => InventoryApi(ref.watch(dioClientProvider).dio),
);
