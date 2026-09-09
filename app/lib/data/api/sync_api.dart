import 'package:dio/dio.dart';

import '../../core/error/api_exception.dart';
import '../models/sync_models.dart';

class SyncApi {
  SyncApi(this._dio);

  final Dio _dio;

  Future<SyncBatchResult> push(List<SyncMutationInput> mutations) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/sync',
        data: {'mutations': mutations.map((m) => m.toJson()).toList()},
      );
      return SyncBatchResult.fromJson(response.data!);
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }
}
