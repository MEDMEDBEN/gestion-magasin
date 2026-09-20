import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'receptions_models.dart';

/// Accès réseau des réceptions. Aucune règle ici : le serveur refuse la
/// surlivraison, fige le TTC et fait avancer la commande.
class ReceptionsApi {
  ReceptionsApi(this._dio);

  final Dio _dio;

  Future<List<Reception>> list({String? purchaseOrderId, int limit = 50}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/receptions',
        queryParameters: {'limit': limit, 'purchaseOrderId': ?purchaseOrderId},
      );
      return ReceptionPage.fromJson(response.data!).data;
    });
  }

  Future<Reception> create(Map<String, Object?> fields) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/receptions',
        data: fields,
      );
      return Reception.fromJson(response.data!);
    });
  }
}

final receptionsApiProvider = Provider<ReceptionsApi>(
  (ref) => ReceptionsApi(ref.watch(dioClientProvider).dio),
);
