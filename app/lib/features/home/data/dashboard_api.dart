import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'dashboard_models.dart';

/// Lecture du résumé d'accueil. Aucune écriture : l'accueil ne fait qu'AFFICHER
/// ce que le serveur accepte de montrer à ce compte.
class DashboardApi {
  DashboardApi(this._dio);

  final Dio _dio;

  Future<DashboardSummary> summary() {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>('/dashboard');
      return DashboardSummary.fromJson(response.data!);
    });
  }
}

final dashboardApiProvider = Provider<DashboardApi>(
  (ref) => DashboardApi(ref.watch(dioClientProvider).dio),
);
