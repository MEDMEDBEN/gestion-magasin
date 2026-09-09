import 'package:dio/dio.dart';

import 'error_codes.dart';

/// Erreur applicative normalisée, construite à partir de l'enveloppe serveur
/// `{ statusCode, message, error, code? }` (CONVENTIONS.md).
class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.message,
    this.code,
  });

  final int statusCode;
  final String message;

  /// Code métier stable — c'est sur LUI que l'UI se branche.
  final String? code;

  /// Aucune réponse du serveur : on est probablement hors-ligne.
  bool get isOffline => statusCode == 0;

  bool get requiresRelogin =>
      code != null && ErrorCodes.requiresRelogin.contains(code);

  String get userMessage => isOffline
      ? 'Pas de connexion au serveur'
      : ErrorCodes.userMessage(code, message);

  factory ApiException.fromDio(DioException error) {
    final response = error.response;
    if (response == null) {
      return ApiException(
        statusCode: 0,
        message: 'Serveur injoignable',
        code: null,
      );
    }

    final body = response.data;
    if (body is Map) {
      final rawMessage = body['message'];
      return ApiException(
        statusCode: response.statusCode ?? 0,
        // `message` peut être une liste quand class-validator rejette plusieurs champs.
        message: rawMessage is List
            ? rawMessage.join(' · ')
            : (rawMessage?.toString() ?? 'Erreur inconnue'),
        code: body['code'] as String?,
      );
    }

    return ApiException(
      statusCode: response.statusCode ?? 0,
      message: 'Erreur inattendue du serveur',
    );
  }

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}
