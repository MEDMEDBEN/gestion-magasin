import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/file_export.dart';
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

  /// ponytail: une seule page (200 plus récentes) ; paginer « Toutes » quand
  /// l'historique des pertes dépassera ce volume.
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

  /// Fichiers rendus serveur, avec les gardes de la liste : un emplacement
  /// que ce compte ne voit pas n'y figure pas.
  Future<ExportedFile> exportLevels(ExportFormat format) =>
      fetchExport(_dio, '/stock/export', format);

  /// Journal des 12 derniers mois (la liste prend des INSTANTS, `to` exclu).
  Future<ExportedFile> exportMovements(ExportFormat format) {
    final since = DateTime.now().subtract(const Duration(days: 365));
    return fetchExport(
      _dio,
      '/stock/movements/export',
      format,
      query: {'from': since.toUtc().toIso8601String()},
    );
  }
}

final stockApiProvider = Provider<StockApi>(
  (ref) => StockApi(ref.watch(dioClientProvider).dio),
);
