import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'transfers_models.dart';

/// Accès réseau des transferts. Aucune règle ici : le serveur tient la machine
/// à états, refuse la surpréparation et déplace le stock.
class TransfersApi {
  TransfersApi(this._dio);

  final Dio _dio;

  Future<TransferPage> list({String? status, int limit = 200}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/transfers',
        queryParameters: {'limit': limit, 'status': ?status},
      );
      return TransferPage.fromJson(response.data!);
    });
  }

  Future<Transfer> create(Map<String, Object?> fields) =>
      _send('/transfers', fields);

  Future<Transfer> accept(String id) => _send('/transfers/$id/accept', null);

  Future<Transfer> prepare(String id, Map<String, Object?> fields) =>
      _send('/transfers/$id/prepare', fields);

  Future<Transfer> ship(String id) => _send('/transfers/$id/ship', null);

  Future<Transfer> receive(String id, Map<String, Object?> fields) =>
      _send('/transfers/$id/receive', fields);

  /// `status` : `REFUSEE` (le dépôt) ou `ANNULEE` (le demandeur).
  Future<Transfer> cancel(String id, String status) =>
      _send('/transfers/$id/cancel', {'status': status});

  Future<Transfer> _send(String path, Map<String, Object?>? fields) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        path,
        data: fields,
      );
      return Transfer.fromJson(response.data!);
    });
  }
}

final transfersApiProvider = Provider<TransfersApi>(
  (ref) => TransfersApi(ref.watch(dioClientProvider).dio),
);
