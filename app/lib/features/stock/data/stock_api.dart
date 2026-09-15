import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'stock_models.dart';

/// Accès réseau au stock. Aucune logique métier ici : le serveur applique les
/// règles (anti-stock-négatif, validation admin des pertes du magasinier).
class StockApi {
  StockApi(this._dio);

  final Dio _dio;

  Future<StockLevelPage> levels({
    String? productId,
    int page = 1,
    int limit = 200,
  }) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/stock',
        queryParameters: {
          'page': page,
          'limit': limit,
          'productId': ?productId,
        },
      );
      return StockLevelPage.fromJson(response.data!);
    });
  }

  Future<StockMovementPage> movements({
    required String productId,
    int limit = 50,
  }) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/stock/movements',
        queryParameters: {'productId': productId, 'limit': limit},
      );
      return StockMovementPage.fromJson(response.data!);
    });
  }

  Future<StockLossPage> losses({StockLossStatus? status, int limit = 200}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/stock/losses',
        queryParameters: {'limit': limit, 'status': ?status?.code},
      );
      return StockLossPage.fromJson(response.data!);
    });
  }

  /// Quantité POSITIVE, en chaîne décimale — le serveur applique le delta négatif.
  Future<StockLoss> declareLoss({
    required String id,
    required String productId,
    required String locationId,
    required String quantity,
    String? comment,
  }) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/stock/losses',
        data: {
          'id': id,
          'productId': productId,
          'locationId': locationId,
          'quantity': quantity,
          'comment': ?comment,
        },
      );
      return StockLoss.fromJson(response.data!);
    });
  }

  Future<StockLoss> validateLoss(String id) => _decide(id, 'validate', null);

  Future<StockLoss> rejectLoss(String id, {String? note}) =>
      _decide(id, 'reject', {'note': ?note});

  Future<StockLoss> _decide(
    String id,
    String action,
    Map<String, Object?>? body,
  ) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/stock/losses/$id/$action',
        data: body,
      );
      return StockLoss.fromJson(response.data!);
    });
  }
}

final stockApiProvider = Provider<StockApi>(
  (ref) => StockApi(ref.watch(dioClientProvider).dio),
);
