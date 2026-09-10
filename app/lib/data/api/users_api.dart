import 'package:dio/dio.dart';

import '../../core/error/api_exception.dart';
import '../models/user_models.dart';

/// Accès réseau au module Utilisateurs. Aucune logique métier ici.
///
/// Toutes ces routes sont réservées à l'ADMIN côté serveur
/// (`@Roles(ADMIN)` + `user.manage`) : l'UI masque, le backend refuse.
class UsersApi {
  UsersApi(this._dio);

  final Dio _dio;

  Future<UserPage> list({int page = 1, int limit = 50, String? query}) {
    return _guard(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/users',
        queryParameters: {
          'page': page,
          'limit': limit,
          if (query != null && query.isNotEmpty) 'q': query,
        },
      );
      return UserPage.fromJson(response.data!);
    });
  }

  Future<ManagedUser> findOne(String id) {
    return _guard(() async {
      final response = await _dio.get<Map<String, dynamic>>('/users/$id');
      return ManagedUser.fromJson(response.data!);
    });
  }

  /// Le mot de passe fourni est TEMPORAIRE : le serveur force
  /// `mustChangePassword` (règle 14).
  Future<ManagedUser> create({
    String? email,
    String? phone,
    required String fullName,
    required String temporaryPassword,
    required List<String> roles,
  }) {
    return _guard(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/users',
        data: {
          'email': ?email,
          'phone': ?phone,
          'fullName': fullName,
          'temporaryPassword': temporaryPassword,
          'roles': roles,
        },
      );
      return ManagedUser.fromJson(response.data!);
    });
  }

  Future<ManagedUser> update(
    String id, {
    String? fullName,
    String? email,
    String? phone,
    bool? isActive,
    List<String>? roles,
  }) {
    return _guard(() async {
      final response = await _dio.patch<Map<String, dynamic>>(
        '/users/$id',
        data: {
          'fullName': ?fullName,
          'email': ?email,
          'phone': ?phone,
          'isActive': ?isActive,
          'roles': ?roles,
        },
      );
      return ManagedUser.fromJson(response.data!);
    });
  }

  /// Repose un mot de passe temporaire ET coupe toutes les sessions du compte.
  Future<ManagedUser> resetPassword(String id, String temporaryPassword) {
    return _guard(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/users/$id/reset-password',
        data: {'temporaryPassword': temporaryPassword},
      );
      return ManagedUser.fromJson(response.data!);
    });
  }

  /// Téléphone volé, départ d'un employé : coupe l'accès immédiatement.
  Future<int> revokeSessions(String id) {
    return _guard(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/users/$id/revoke-sessions',
      );
      return (response.data?['revoked'] as int?) ?? 0;
    });
  }

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }
}
