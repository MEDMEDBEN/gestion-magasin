import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'suppliers_models.dart';

/// Accès réseau Fournisseurs / dettes. Aucune règle ici : le serveur contrôle
/// les droits, la dette et la caisse.
class SuppliersApi {
  SuppliersApi(this._dio);

  final Dio _dio;

  Future<SupplierPage> list({String? query, bool includeInactive = false}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/suppliers',
        queryParameters: {
          'limit': 200,
          'q': ?query,
          if (includeInactive) 'includeInactive': true,
        },
      );
      return SupplierPage.fromJson(response.data!);
    });
  }

  Future<Supplier> create(Map<String, Object?> fields) =>
      _send('POST', '/suppliers', fields);

  Future<Supplier> update(String id, Map<String, Object?> fields) =>
      _send('PATCH', '/suppliers/$id', fields);

  /// Paiement : `fromCash` = sortie de la caisse ouverte, sinon hors caisse.
  Future<SupplierPayment> pay(Map<String, Object?> fields) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/payments/supplier',
        data: fields,
      );
      return SupplierPayment.fromJson(response.data!);
    });
  }

  Future<Supplier> _send(
    String method,
    String path,
    Map<String, Object?> fields,
  ) {
    return guardApi(() async {
      final response = await _dio.request<Map<String, dynamic>>(
        path,
        data: fields,
        options: Options(method: method),
      );
      return Supplier.fromJson(response.data!);
    });
  }
}

final suppliersApiProvider = Provider<SuppliersApi>(
  (ref) => SuppliersApi(ref.watch(dioClientProvider).dio),
);
