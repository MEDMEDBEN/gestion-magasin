import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'replenishment_models.dart';

/// Réapprovisionnement (spec §19). Lecture seule : commander passe par la
/// commande fournisseur existante, pas par cet écran.
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
}

final replenishmentApiProvider = Provider<ReplenishmentApi>(
  (ref) => ReplenishmentApi(ref.watch(dioClientProvider).dio),
);
