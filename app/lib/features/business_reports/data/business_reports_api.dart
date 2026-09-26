import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/file_export.dart';
import '../../../core/providers.dart';
import 'business_report_models.dart';

/// Rapports ventes / stock / achats (spec §21). Lecture seule, ADMIN seul côté
/// serveur — l'écran n'est proposé qu'à l'admin, le serveur le revérifie.
class BusinessReportsApi {
  BusinessReportsApi(this._dio);

  final Dio _dio;

  Future<SalesReport> sales({String? from, String? to}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/reports/sales',
        queryParameters: {'from': ?from, 'to': ?to},
      );
      return SalesReport.fromJson(response.data!);
    });
  }

  Future<StockReport> stock() {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>('/reports/stock');
      return StockReport.fromJson(response.data!);
    });
  }

  Future<PurchasesReport> purchases({String? from, String? to}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/reports/purchases',
        queryParameters: {'from': ?from, 'to': ?to},
      );
      return PurchasesReport.fromJson(response.data!);
    });
  }

  /// Fichier d'un rapport (`sales`, `stock`, `purchases`), rendu serveur, avec
  /// la même garde ADMIN que la lecture. Le stock ignore la période.
  Future<ExportedFile> export(
    String report,
    ExportFormat format, {
    String? from,
    String? to,
  }) {
    return fetchExport(
      _dio,
      '/reports/$report/export',
      format,
      query: {'from': ?from, 'to': ?to},
    );
  }
}

final businessReportsApiProvider = Provider<BusinessReportsApi>(
  (ref) => BusinessReportsApi(ref.watch(dioClientProvider).dio),
);
