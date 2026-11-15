import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/file_export.dart';
import '../../../core/providers.dart';
import 'inventory_models.dart';

/// Accès réseau de l'inventaire. Aucune règle ici : le serveur fige le
/// Produit suggéré au comptage (demande MEDMEDBEN du 2026-11-15).
typedef CountSuggestion = ({
  String productId,
  String name,
  String sku,
  int movements,
  DateTime? lastCountedAt,
});

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

  /// Produits À SURVEILLER : les plus mouvementés, non comptés depuis 24 h.
  Future<List<CountSuggestion>> suggestions({int days = 7, int limit = 8}) {
    return guardApi(() async {
      final response = await _dio.get<List<dynamic>>(
        '/inventories/suggestions',
        queryParameters: {'days': days, 'limit': limit},
      );
      return [
        for (final row in response.data!.cast<Map<String, dynamic>>())
          (
            productId: row['productId'] as String,
            name: row['name'] as String,
            sku: row['sku'] as String,
            movements: row['movements'] as int,
            lastCountedAt: row['lastCountedAt'] == null
                ? null
                : DateTime.parse(row['lastCountedAt'] as String),
          ),
      ];
    });
  }

  Future<Inventory> create(Map<String, Object?> fields) =>
      _send('/inventories', fields);

  Future<Inventory> count(String id, Map<String, Object?> fields) =>
      _send('/inventories/$id/count', fields);

  Future<Inventory> validate(String id) =>
      _send('/inventories/$id/validate', null);

  /// Supprime un inventaire PAS ENCORE ajusté (aucun stock ne bouge).
  Future<void> remove(String id) => guardApi(() async {
    await _dio.delete<void>('/inventories/$id');
  });

  Future<Inventory> _send(String path, Map<String, Object?>? fields) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        path,
        data: fields,
      );
      return Inventory.fromJson(response.data!);
    });
  }

  /// Inventaires et leurs lignes comptées.
  Future<ExportedFile> exportInventories(ExportFormat format) =>
      fetchExport(_dio, '/inventories/export', format);
}

final inventoryApiProvider = Provider<InventoryApi>(
  (ref) => InventoryApi(ref.watch(dioClientProvider).dio),
);
