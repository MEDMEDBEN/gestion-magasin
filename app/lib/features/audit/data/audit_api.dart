import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'audit_models.dart';

/// Lecture du journal d'audit (admin). Aucune écriture : le journal est
/// immuable, le serveur n'expose d'ailleurs aucune route pour le modifier.
class AuditApi {
  AuditApi(this._dio);

  final Dio _dio;

  Future<AuditPage> list({
    int page = 1,
    int limit = 50,
    String? entityType,
    AuditAction? action,
    String? from,
  }) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/audit-logs',
        queryParameters: {
          'page': page,
          'limit': limit,
          'entityType': ?entityType,
          'action': ?action?.wire,
          'from': ?from,
        },
      );
      return AuditPage.fromJson(response.data!);
    });
  }
}

final auditApiProvider = Provider<AuditApi>(
  (ref) => AuditApi(ref.watch(dioClientProvider).dio),
);
