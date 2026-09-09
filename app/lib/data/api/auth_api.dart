import 'package:dio/dio.dart';

import '../../core/error/api_exception.dart';
import '../models/auth_models.dart';

/// Accès réseau au module Auth. Aucune logique métier ici : le contrôleur
/// Riverpod décide, ce repository transporte.
class AuthApi {
  AuthApi(this._dio);

  final Dio _dio;

  Future<AuthSession> login({
    required String identifier,
    required String password,
    String? deviceId,
    String? deviceName,
  }) async {
    return _guard(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/login',
        data: {
          'identifier': identifier,
          'password': password,
          'deviceId': ?deviceId,
          'deviceName': ?deviceName,
        },
        // Pas d'access token à joindre, et surtout pas de refresh automatique
        // sur un échec de login : ce serait absurde.
        options: Options(extra: {'skipAuth': true}),
      );
      return AuthSession.fromJson(response.data!);
    });
  }

  Future<AuthUser> me() async {
    return _guard(() async {
      final response = await _dio.get<Map<String, dynamic>>('/auth/me');
      return AuthUser.fromJson(response.data!);
    });
  }

  /// Renvoie une session NEUVE : le serveur révoque toutes les anciennes.
  Future<AuthSession> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    return _guard(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/change-password',
        data: {
          'currentPassword': currentPassword,
          'newPassword': newPassword,
        },
      );
      return AuthSession.fromJson(response.data!);
    });
  }

  Future<void> logout({String? refreshToken, bool allDevices = false}) async {
    return _guard(() async {
      await _dio.post<Map<String, dynamic>>(
        '/auth/logout',
        data: {
          'refreshToken': ?refreshToken,
          'allDevices': allDevices,
        },
      );
    });
  }

  /// Traduit toute erreur Dio en `ApiException` porteuse du code métier stable.
  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }
}
