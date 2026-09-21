import 'package:dio/dio.dart';

import '../../core/error/api_exception.dart';
import '../models/sync_models.dart';

class SyncApi {
  SyncApi(this._dio);

  final Dio _dio;

  /// Même traduction d'erreurs que les autres API (`guardApi`) : une seule
  /// façon de convertir un échec réseau en `ApiException` (contre-revue S9).
  /// `authorUserId` : le compte AUTEUR des mutations. Le serveur refuse de
  /// traiter un lot dont l'auteur n'est pas le porteur de la session (N6b).
  Future<SyncBatchResult> push(
    List<SyncMutationInput> mutations, {
    required String authorUserId,
  }) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/sync',
        data: {
          'authorUserId': authorUserId,
          'mutations': mutations.map((m) => m.toJson()).toList(),
        },
      );
      return SyncBatchResult.fromJson(response.data!);
    });
  }
}
