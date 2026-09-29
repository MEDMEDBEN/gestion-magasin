import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'replenishment_models.dart';

/// Réapprovisionnement (spec §19) et préparation des commandes (P2 n°22) :
/// des BROUILLONS, une par fournisseur principal, à vérifier dans Achats.
class ReplenishmentApi {
  ReplenishmentApi(this._dio);

  final Dio _dio;

  Future<ReplenishmentPage> list({
    int page = 1,
    int limit = 50,
    bool outOfStockOnly = false,
    String? supplierId,
  }) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/replenishment',
        queryParameters: {
          'page': page,
          'limit': limit,
          if (outOfStockOnly) 'outOfStockOnly': 'true',
          'supplierId': ?supplierId,
        },
      );
      return ReplenishmentPage.fromJson(response.data!);
    });
  }

  /// Rend `orders` (id, number, supplierName, lineCount) et `withoutSupplier`
  /// (noms des produits sans fournisseur principal).
  Future<Map<String, dynamic>> prepareOrders(
    List<({String productId, String quantity})> lines,
  ) => guardApi(() async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/replenishment/orders',
      data: {
        'lines': [
          for (final l in lines)
            {'productId': l.productId, 'quantity': l.quantity},
        ],
      },
    );
    return response.data!;
  });
}

final replenishmentApiProvider = Provider<ReplenishmentApi>(
  (ref) => ReplenishmentApi(ref.watch(dioClientProvider).dio),
);
