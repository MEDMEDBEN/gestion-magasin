import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'auth_models.dart';

/// Accès réseau au module Auth. Aucune logique métier ici : le contrôleur
/// Riverpod décide, ce client transporte.
class AuthApi {
  AuthApi(this._dio);

  final Dio _dio;

  /// Ni access token à joindre, ni refresh automatique sur un échec.
  static final _public = Options(extra: {'skipAuth': true});

  Future<AuthSession> login({
    required String identifier,
    required String password,
    String? deviceId,
    String? deviceName,
  }) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/login',
        data: {
          'identifier': identifier,
          'password': password,
          'deviceId': ?deviceId,
          'deviceName': ?deviceName,
        },
        options: _public,
      );
      return AuthSession.fromJson(response.data!);
    });
  }

  Future<AuthUser> me() {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>('/auth/me');
      return AuthUser.fromJson(response.data!);
    });
  }

  /// Renvoie une session NEUVE : le serveur révoque toutes les anciennes.
  /// `deviceId` : la session neuve reste rattachée à cet appareil.
  Future<AuthSession> changePassword({
    required String currentPassword,
    required String newPassword,
    String? deviceId,
  }) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/change-password',
        data: {
          'currentPassword': currentPassword,
          'newPassword': newPassword,
          'deviceId': ?deviceId,
        },
      );
      return AuthSession.fromJson(response.data!);
    });
  }

  /// Route PUBLIQUE : le refresh token est la preuve de possession. Envoyé sans
  /// access token — sinon, s'il était expiré, l'intercepteur rafraîchirait
  /// d'abord et le logout révoquerait l'ancien token en laissant le neuf vivant.
  /// Renvoie le nombre de sessions fermées.
  Future<int> logout({required String refreshToken, bool allDevices = false}) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/logout',
        data: {'refreshToken': refreshToken, 'allDevices': allDevices},
        options: _public,
      );
      return (response.data?['revoked'] as int?) ?? 0;
    });
  }
}

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(dioClientProvider).dio),
);
