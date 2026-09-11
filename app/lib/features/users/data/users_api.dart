import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'user_models.dart';

/// Accès réseau au module Utilisateurs. Aucune logique métier ici.
///
/// Toutes ces routes sont réservées à l'ADMIN côté serveur
/// (`@Roles(ADMIN)` + `user.manage`, accès relu en base) : l'UI masque, le
/// backend refuse.
class UsersApi {
  UsersApi(this._dio);

  final Dio _dio;

  Future<UserPage> list({int page = 1, int limit = 50, String? query}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/users',
        queryParameters: {
          'page': page,
          'limit': limit,
          'sort': 'fullName:asc',
          if (query != null && query.isNotEmpty) 'q': query,
        },
      );
      return UserPage.fromJson(response.data!);
    });
  }

  /// Rôles et permissions attribuables, lus dans la matrice serveur.
  Future<PermissionCatalog> permissionCatalog() {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/users/permission-catalog',
      );
      return PermissionCatalog.fromJson(response.data!);
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
    List<String> extraPermissions = const [],
  }) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/users',
        data: {
          'email': ?email,
          'phone': ?phone,
          'fullName': fullName,
          'temporaryPassword': temporaryPassword,
          'roles': roles,
          if (extraPermissions.isNotEmpty) 'extraPermissions': extraPermissions,
        },
      );
      return ManagedUser.fromJson(response.data!);
    });
  }

  Future<ManagedUser> update(String id, UserChanges changes) {
    return guardApi(() async {
      final response = await _dio.patch<Map<String, dynamic>>(
        '/users/$id',
        data: changes.toJson(),
      );
      return ManagedUser.fromJson(response.data!);
    });
  }

  /// Repose un mot de passe temporaire ET coupe toutes les sessions du compte.
  Future<ManagedUser> resetPassword(String id, String temporaryPassword) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/users/$id/reset-password',
        data: {'temporaryPassword': temporaryPassword},
      );
      return ManagedUser.fromJson(response.data!);
    });
  }

  /// Téléphone volé, départ d'un employé : plus aucun renouvellement de
  /// session possible (un accès déjà ouvert s'éteint sous 15 min au plus).
  Future<int> revokeSessions(String id) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/users/$id/revoke-sessions',
      );
      return (response.data?['revoked'] as int?) ?? 0;
    });
  }
}

final usersApiProvider =
    Provider<UsersApi>((ref) => UsersApi(ref.watch(dioClientProvider).dio));
