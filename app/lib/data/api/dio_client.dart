import 'dart:async';

import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';
import '../../core/error/error_codes.dart';
import '../local/token_store.dart';

/// Client HTTP UNIQUE du projet (CONVENTIONS.md § HTTP).
/// Aucun appel réseau ne doit être fait ailleurs qu'à travers un repository
/// qui utilise cette instance.
class DioClient {
  DioClient({
    required TokenStore tokenStore,
    required Future<void> Function() onSessionExpired,
    String? baseUrl,
    Dio? dio,
  }) : _tokenStore = tokenStore,
       _onSessionExpired = onSessionExpired {
    this.dio = dio ??
        Dio(
          BaseOptions(
            baseUrl: baseUrl ?? AppConfig.apiBaseUrl,
            connectTimeout: AppConfig.requestTimeout,
            receiveTimeout: AppConfig.requestTimeout,
            contentType: Headers.jsonContentType,
          ),
        );
    this.dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: _attachAccessToken,
            onError: _refreshOnUnauthorized,
          ),
        );
  }

  late final Dio dio;
  final TokenStore _tokenStore;
  final Future<void> Function() _onSessionExpired;

  /// Refresh EN VOL, partagé par tous les appels concurrents.
  ///
  /// Indispensable : le serveur fait tourner le refresh token et traite le rejeu
  /// d'un token révoqué comme un vol, en fermant TOUTES les sessions. Deux appels
  /// qui rafraîchiraient en parallèle déconnecteraient donc l'utilisateur.
  Future<bool>? _refreshInFlight;

  Future<void> _attachAccessToken(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra['skipAuth'] != true) {
      final token = await _tokenStore.readAccessToken();
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }
    handler.next(options);
  }

  Future<void> _refreshOnUnauthorized(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    final response = error.response;
    final code = response?.data is Map
        ? (response!.data as Map)['code'] as String?
        : null;

    final isExpiredAccessToken = response?.statusCode == 401 &&
        (code == ErrorCodes.accessTokenInvalid ||
            code == ErrorCodes.accessTokenMissing);

    // On ne rejoue jamais une requête déjà rejouée : sinon boucle infinie.
    final alreadyRetried = error.requestOptions.extra['retried'] == true;
    final isRefreshCall = error.requestOptions.extra['skipAuth'] == true;

    if (!isExpiredAccessToken || alreadyRetried || isRefreshCall) {
      return handler.next(error);
    }

    // Un autre appel a peut-être DÉJÀ rafraîchi entre-temps : cette requête
    // porte alors un access token périmé alors que le store en a un neuf.
    // Rejouer directement évite une rotation inutile (le quota de /auth/refresh
    // est limité côté serveur, l'épuiser casserait la session).
    final currentToken = await _tokenStore.readAccessToken();
    final sentToken =
        (error.requestOptions.headers['Authorization'] as String?)
            ?.replaceFirst('Bearer ', '');
    if (currentToken != null && sentToken != null && currentToken != sentToken) {
      return _replay(error, handler);
    }

    final refreshed = await _refreshTokens();
    if (!refreshed) {
      return handler.next(error);
    }

    return _replay(error, handler);
  }

  /// Rejoue la requête d'origine avec le token courant.
  Future<void> _replay(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    try {
      final options = error.requestOptions..extra['retried'] = true;
      // L'en-tête est réécrit par `_attachAccessToken` au passage suivant.
      options.headers.remove('Authorization');
      final retried = await dio.fetch(options);
      return handler.resolve(retried);
    } on DioException catch (retryError) {
      return handler.next(retryError);
    }
  }

  /// Instant du dernier échec PASSAGER, pour ne pas marteler l'endpoint.
  DateTime? _lastTransientFailure;

  /// Fenêtre de silence après un échec passager. `/auth/refresh` est throttlé
  /// côté serveur : sans ce garde-fou, dix requêtes en 401 déclencheraient dix
  /// tentatives successives et brûleraient le quota.
  static const Duration _refreshCooldown = Duration(seconds: 5);

  /// Renouvelle les tokens. Un seul appel réel, même si dix requêtes échouent
  /// simultanément — les autres attendent le même résultat.
  Future<bool> _refreshTokens() async {
    final lastFailure = _lastTransientFailure;
    if (lastFailure != null &&
        DateTime.now().difference(lastFailure) < _refreshCooldown) {
      return false;
    }
    return _refreshInFlight ??= _performRefresh().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<bool> _performRefresh() async {
    final refreshToken = await _tokenStore.readRefreshToken();
    if (refreshToken == null) {
      await _onSessionExpired();
      return false;
    }

    try {
      final response = await dio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refreshToken': refreshToken},
        options: Options(extra: {'skipAuth': true}),
      );

      final data = response.data!;
      // Rotation : l'ancien refresh est mort côté serveur, on DOIT stocker le neuf.
      await _tokenStore.saveTokens(
        accessToken: data['accessToken'] as String,
        refreshToken: data['refreshToken'] as String,
      );
      _lastTransientFailure = null;
      return true;
    } on DioException catch (error) {
      final status = error.response?.statusCode ?? 0;

      // Panne PASSAGÈRE (5xx, quota, timeout côté serveur) : le serveur n'a pas
      // fait tourner le token. Effacer la session ici déconnecterait l'appareil
      // sur un simple hoquet — et couperait l'accès à des ventes hors-ligne
      // encore dans la file. On garde tout et on réessaiera.
      if (status >= 500 || status == 429 || status == 408) {
        _lastTransientFailure = DateTime.now();
        return false;
      }

      // `status == 0` = aucune réponse reçue. Cas ambigu : la rotation a
      // peut-être abouti côté serveur et seule la réponse s'est perdue. Rejouer
      // le token serait interprété comme un VOL et fermerait TOUTES les
      // sessions ; on préfère redemander un login sur ce seul appareil.
      await _tokenStore.clear();
      await _onSessionExpired();
      return false;
    }
  }
}
