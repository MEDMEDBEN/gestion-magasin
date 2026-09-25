import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'problem_models.dart';

/// Signalements de l'équipe (spec §26). Aucune écriture de stock ici : le
/// serveur n'en fait pas non plus.
class ProblemsApi {
  ProblemsApi(this._dio);

  final Dio _dio;

  Future<ProblemPage> list({
    int page = 1,
    int limit = 50,
    ProblemStatus? status,
    bool mine = false,
  }) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/problems',
        queryParameters: {
          'page': page,
          'limit': limit,
          'status': ?status?.wire,
          if (mine) 'mine': 'true',
        },
      );
      return ProblemPage.fromJson(response.data!);
    });
  }

  Future<Problem> create({
    required String title,
    required ProblemCategory category,
    required String description,
    required ProblemPriority priority,
    String? productId,
    String? locationId,
  }) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/problems',
        data: {
          'title': title,
          'category': category.wire,
          'description': description,
          'priority': priority.wire,
          'productId': ?productId,
          'locationId': ?locationId,
        },
      );
      return Problem.fromJson(response.data!);
    });
  }

  Future<Problem> start(String id) => _act(id, 'start');

  Future<Problem> resolve(String id, String resolution) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/problems/$id/resolve',
        data: {'resolution': resolution},
      );
      return Problem.fromJson(response.data!);
    });
  }

  Future<Problem> close(String id) => _act(id, 'close');

  Future<Problem> assign(String id, String assignedToId) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/problems/$id/assign',
        data: {'assignedToId': assignedToId},
      );
      return Problem.fromJson(response.data!);
    });
  }

  /// Transitions sans corps : le serveur décide de ce qui est permis.
  Future<Problem> _act(String id, String action) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/problems/$id/$action',
      );
      return Problem.fromJson(response.data!);
    });
  }

  /// Photo jointe (auteur du signalement ou admin). Le serveur lit le format
  /// dans les OCTETS : un fichier qui n'est pas une image est refusé, quel que
  /// soit son nom.
  Future<Problem> attachPhoto(String id, Uint8List bytes) {
    return guardApi(() async {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: 'photo.jpg'),
      });
      final response = await _dio.post<Map<String, dynamic>>(
        '/problems/$id/photo',
        data: form,
      );
      return Problem.fromJson(response.data!);
    });
  }

  /// La photo ne sort que par cette route authentifiée : le stockage serveur
  /// est privé, il n'y a pas d'URL publique à mettre dans un `Image.network`.
  Future<Uint8List> photoBytes(String id) {
    return guardApi(() async {
      final response = await _dio.get<List<int>>(
        '/problems/$id/photo',
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data!);
    });
  }
}

final problemsApiProvider = Provider<ProblemsApi>(
  (ref) => ProblemsApi(ref.watch(dioClientProvider).dio),
);
