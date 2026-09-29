import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/error/error_codes.dart';
import '../../../core/providers.dart';
import '../../../data/api/dio_client.dart';
import '../data/auth_api.dart';
import '../data/auth_models.dart';

/// État d'authentification de l'application.
sealed class AuthState {
  const AuthState();
}

/// Au démarrage : on ne sait pas encore s'il existe une session valide.
class AuthUnknown extends AuthState {
  const AuthUnknown();
}

class AuthSignedOut extends AuthState {
  const AuthSignedOut({this.message});

  /// Motif de la déconnexion (session expirée, compte désactivé…).
  final String? message;
}

class AuthSignedIn extends AuthState {
  const AuthSignedIn(this.user);
  final AuthUser user;

  /// Tant que c'est vrai, l'API entière est verrouillée côté serveur :
  /// l'app DOIT rediriger vers le changement de mot de passe.
  bool get mustChangePassword => user.mustChangePassword;
}

/// Pilote la session : connexion, restauration au démarrage, changement de mot
/// de passe, déconnexion. Aucune logique de ce genre dans les widgets.
class AuthController extends AsyncNotifier<AuthState> {
  /// Session ouverte HORS LIGNE sur la fiche gardée : le serveur ne l'a pas
  /// encore reconnue. Revérifiée dès qu'il répond.
  bool _unverified = false;
  bool _checking = false;

  /// Fermeture de session en cours (déconnexion) : aucune vérification ne
  /// démarre, elle rouvrirait la session que l'on est en train de fermer.
  bool _closing = false;

  /// Change à chaque ouverture ou fermeture de session : une vérification
  /// lancée avant n'écrit plus rien après (déconnexion pendant l'appel).
  int _epoch = 0;

  /// En ligne, la fiche gardée est relue au serveur toutes les heures (droits
  /// changés par l'admin, date de contact à jour). Compté en battements, pas
  /// à l'horloge de l'appareil.
  int _ticksSinceRemember = 0;
  static final _profileRefreshTicks =
      const Duration(hours: 1).inSeconds ~/ AppConfig.syncInterval.inSeconds;

  @override
  Future<AuthState> build() async {
    _unverified = false;
    // Retour du réseau : une session ouverte hors ligne est revérifiée tout de
    // suite. Le battement couvre la panne serveur (5xx), où le réseau n'a
    // jamais été vu « coupé » et ne « revient » donc pas.
    ref.listen(serverReachableProvider, (_, reachable) {
      if (reachable && _unverified) unawaited(_checkWithServer());
    });
    final timer = Timer.periodic(
      AppConfig.syncInterval,
      (_) => unawaited(_tick()),
    );
    ref.onDispose(timer.cancel);
    return _restoreSession();
  }

  Future<void> _tick() async {
    if (_unverified) {
      // Le temps passé hors ligne compte, même si l'horloge est reculée — et
      // la borne des 72 h vaut aussi app OUVERTE : dépassée, retour à l'écran
      // « serveur injoignable », sans rien effacer (file, tokens).
      try {
        final tokenStore = ref.read(tokenStoreProvider);
        await tokenStore.markOfflineSeen();
        final saved = await tokenStore.readOfflineUser();
        if (saved == null ||
            !offlineStartAllowed(
              saved.serverContactAt,
              DateTime.now().toUtc(),
              lastSeen: saved.lastSeen,
            )) {
          if (!ref.mounted || !_unverified) return;
          _unverified = false;
          _epoch++;
          state = const AsyncValue.data(AuthUnknown());
          return;
        }
      } on Object {
        // Stockage indisponible : la vérification suit quand même.
      }
      return _checkWithServer();
    }
    if (++_ticksSinceRemember >= _profileRefreshTicks) {
      await _checkWithServer();
    }
  }

  /// Une session peut s'ouvrir hors ligne si le serveur l'a reconnue il y a
  /// moins de `maxOfflineDuration` (72 h, la borne du travail hors ligne).
  /// L'âge se mesure jusqu'à l'instant le plus tardif DÉJÀ VU par l'appareil
  /// (`lastSeen`) : reculer l'horloge ne rend pas de temps. Une horloge avant
  /// le dernier contact est refusée.
  /// ponytail: horloge de l'appareil, relevée toutes les 30 s ; qui la recule
  /// à chaque lancement gagne au plus le temps app fermée. Le serveur, lui,
  /// rejuge chaque opération au sync.
  static bool offlineStartAllowed(
    DateTime serverContactAt,
    DateTime now, {
    DateTime? lastSeen,
  }) {
    if (now.isBefore(serverContactAt)) return false;
    final latest = lastSeen != null && lastSeen.isAfter(now) ? lastSeen : now;
    return latest.difference(serverContactAt) <= AppConfig.maxOfflineDuration;
  }

  /// Compte (`sub`) d'un access token, lu SANS vérifier la signature : sert
  /// seulement à ne pas mélanger deux comptes sur l'appareil, jamais à donner
  /// un droit (le serveur juge chaque requête).
  static String? tokenSubject(String? accessToken) {
    final parts = accessToken?.split('.');
    if (parts == null || parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return payload is Map<String, dynamic> ? payload['sub'] as String? : null;
    } on Object {
      return null;
    }
  }

  /// Garde la fiche du compte (reconnu par le serveur à l'instant) pour un
  /// prochain démarrage sans réseau. Un échec du stockage ne casse pas la
  /// session en ligne : seul le démarrage hors ligne suivant en pâtira.
  Future<void> _remember(AuthUser user) async {
    try {
      await ref
          .read(tokenStoreProvider)
          .saveOfflineUser(jsonEncode(user.toJson()));
    } on Object {
      // Stockage indisponible : on réessaiera à la relecture suivante.
    }
    _ticksSinceRemember = 0;
  }

  /// Serveur injoignable au lancement : la fiche gardée ouvre l'app, si elle
  /// est assez récente et bien celle du compte des tokens. Sinon `null`
  /// (écran « serveur injoignable »).
  Future<AuthSignedIn?> _offlineSession() async {
    final tokenStore = ref.read(tokenStoreProvider);
    final saved = await tokenStore.readOfflineUser();
    if (saved == null ||
        !offlineStartAllowed(
          saved.serverContactAt,
          DateTime.now().toUtc(),
          lastSeen: saved.lastSeen,
        )) {
      return null;
    }
    final AuthUser user;
    try {
      user = AuthUser.fromJson(
        jsonDecode(saved.userJson) as Map<String, dynamic>,
      );
    } on Object {
      return null; // Fiche illisible (ancienne version) : pas de hors-ligne.
    }
    // Mot de passe temporaire : le serveur refuserait tout, rien à faire ici.
    if (user.mustChangePassword) return null;
    // La fiche doit être celle du compte des tokens : jamais l'app au nom de
    // A avec la file et la session de B (poste partagé).
    if (tokenSubject(await tokenStore.readAccessToken()) != user.id) {
      return null;
    }
    try {
      await tokenStore.markOfflineSeen();
    } on Object {
      return null; // Stockage indisponible : pas de hors-ligne.
    }
    _unverified = true;
    return AuthSignedIn(user);
  }

  /// Relit le compte au serveur : reconnaît une session ouverte hors ligne,
  /// ou rafraîchit la fiche gardée d'une session en ligne. Réseau absent ou
  /// hoquet (5xx, 408, 429, refresh en pause) : on réessaiera au battement
  /// suivant. Session finie (refresh refusé, compte désactivé, plus aucun
  /// rôle, compte introuvable) : retour au login, tout effacé.
  Future<void> _checkWithServer() async {
    final current = state.value;
    if (_checking || _closing || !ref.mounted || current is! AuthSignedIn) {
      return;
    }
    _checking = true;
    final epoch = _epoch;
    bool stale() => !ref.mounted || _closing || epoch != _epoch;
    try {
      final user = await ref.read(authApiProvider).me();
      if (stale()) return;
      await _remember(user);
      if (stale()) return;
      _unverified = false;
      state = AsyncValue.data(AuthSignedIn(user));
    } on ApiException catch (error) {
      if (stale()) return;
      if (error.requiresRelogin ||
          error.statusCode == 403 ||
          error.statusCode == 404) {
        await _endSession(current.user.id, error.userMessage);
      }
    } on Object {
      // Boucle de fond : une erreur imprévue se réessaie au battement suivant.
    } finally {
      _checking = false;
    }
  }

  /// Ferme la session locale et le dit (`message`).
  Future<void> _endSession(String? userId, String? message) async {
    _unverified = false;
    _epoch++;
    _closing = true;
    try {
      await _wipe(userId);
      state = AsyncValue.data(AuthSignedOut(message: message));
    } finally {
      _closing = false;
    }
  }

  /// Efface tokens, fiche gardée et documents hors ligne du compte (le poste
  /// est partagé, sa base locale n'est pas chiffrée). Compte inconnu (session
  /// refusée au démarrage) : celui de l'access token.
  Future<void> _wipe(String? userId) async {
    final tokenStore = ref.read(tokenStoreProvider);
    final account = userId ?? tokenSubject(await tokenStore.readAccessToken());
    await tokenStore.clear();
    if (account != null) {
      await ref.read(documentCacheProvider).clear(account);
    }
  }

  /// Session persistante : si un refresh token valide existe, l'utilisateur
  /// n'a pas à ressaisir son mot de passe (spec §2bis).
  Future<AuthState> _restoreSession() async {
    final tokenStore = ref.read(tokenStoreProvider);
    final refreshToken = await tokenStore.readRefreshToken();
    if (refreshToken == null) return const AuthSignedOut();

    try {
      // `/auth/me` déclenche au besoin le refresh automatique de l'intercepteur.
      final user = await ref.read(authApiProvider).me();
      await _remember(user);
      return AuthSignedIn(user);
    } on ApiException catch (error) {
      // Hors-ligne (ou panne serveur) au lancement : on ne déconnecte SURTOUT
      // pas. La fiche gardée ouvre l'app en mode hors ligne ; sans elle (ou
      // trop ancienne), écran « serveur injoignable » avec Réessayer.
      if (error.isOffline || error.statusCode >= 500) {
        return await _offlineSession() ?? const AuthUnknown();
      }

      // Session réellement finie (401, refresh révoqué/expiré, compte désactivé).
      if (error.statusCode == 401 || error.requiresRelogin) {
        await _wipe(null);
        return AuthSignedOut(message: error.userMessage);
      }

      // 403 : la session est techniquement valide mais le compte ne peut pas
      // utiliser l'app (aucun rôle attribué, par exemple). Le renvoyer en
      // « non résolu » afficherait « serveur injoignable » et un bouton
      // Réessayer qui boucle. On le dit clairement ; les tokens restent (l'admin
      // peut rendre un rôle), mais la fiche gardée n'ouvrira plus rien hors
      // ligne. En cours de session (`_checkWithServer`), le même 403 ferme
      // tout : l'utilisateur est alors DANS l'app et doit en sortir.
      if (error.statusCode == 403) {
        await tokenStore.clearOfflineUser();
        return AuthSignedOut(message: error.userMessage);
      }

      return const AuthUnknown();
    }
  }

  Future<void> login({
    required String identifier,
    required String password,
  }) async {
    _unverified = false;
    _epoch++;
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      // La fiche d'un compte précédent ne survit pas à une connexion.
      await ref.read(tokenStoreProvider).clearOfflineUser();
      final deviceId = await ref.read(deviceIdProvider.future);
      final session = await ref
          .read(authApiProvider)
          .login(
            identifier: identifier,
            password: password,
            deviceId: deviceId,
          );
      await ref
          .read(tokenStoreProvider)
          .saveTokens(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
          );
      await _remember(session.user);
      return AuthSignedIn(session.user);
    });
  }

  /// Change le mot de passe. Lève `ApiException` en cas de refus : l'écran
  /// gère SON état (envoi en cours, erreur) — l'état global de session ne passe
  /// jamais en chargement, sinon toute la coquille serait démontée pendant
  /// l'appel et l'utilisateur perdrait sa navigation (revue C9).
  ///
  /// Le serveur révoque toutes les sessions et renvoie des tokens neufs : on
  /// les stocke, sinon l'utilisateur serait déconnecté juste après.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    // Une vérification partie avant n'écrit pas l'ancien profil par-dessus.
    _epoch++;
    final deviceId = await ref.read(deviceIdProvider.future);
    final session = await ref
        .read(authApiProvider)
        .changePassword(
          currentPassword: currentPassword,
          newPassword: newPassword,
          deviceId: deviceId,
        );
    await ref
        .read(tokenStoreProvider)
        .saveTokens(
          accessToken: session.accessToken,
          refreshToken: session.refreshToken,
        );
    _unverified = false;
    await _remember(session.user);
    state = AsyncValue.data(AuthSignedIn(session.user));
  }

  /// Déconnexion de CET appareil. Au mieux : hors-ligne, la session serveur ne
  /// peut pas être fermée tout de suite, mais la session locale l'est — et le
  /// refresh token, jamais réutilisé, expirera.
  Future<void> logout() async {
    _unverified = false;
    _epoch++;
    _closing = true;
    final tokenStore = ref.read(tokenStoreProvider);
    final client = ref.read(dioClientProvider);
    // Aucune rotation ne démarre pendant la fermeture, et on lit le refresh
    // token APRÈS celle qui serait déjà en vol (N8 + audit final, mineur 2).
    client.beginSessionClose();
    try {
      await client.awaitPendingRefresh();
      final refreshToken = await tokenStore.readRefreshToken();
      if (refreshToken != null) {
        try {
          await ref.read(authApiProvider).logout(refreshToken: refreshToken);
        } on ApiException {
          // Voir ci-dessus : l'échec serveur n'empêche pas la déconnexion locale.
        }
      }
      await tokenStore.clear();
      // Les documents de travail gardés pour le hors-ligne ne survivent pas à
      // la session : le poste est partagé, sa base locale n'est pas chiffrée.
      final userId = switch (state.value) {
        AuthSignedIn(:final user) => user.id,
        _ => null,
      };
      if (userId != null) {
        await ref.read(documentCacheProvider).clear(userId);
      }
      state = const AsyncValue.data(AuthSignedOut());
    } finally {
      client.endSessionClose();
      _closing = false;
    }
  }

  /// Ferme TOUTES les sessions du compte (perte, vol, départ).
  ///
  /// Contrairement à `logout`, un échec n'est JAMAIS avalé : l'utilisateur qui
  /// croit son téléphone volé déconnecté alors que la requête a échoué laisserait
  /// une session valide 90 jours au voleur (audit I3). La session locale est
  /// alors conservée et l'`ApiException` remonte à l'écran.
  Future<int> logoutAllDevices() async {
    final client = ref.read(dioClientProvider);
    client.beginSessionClose();
    try {
      return await _logoutAllDevices(client);
    } finally {
      client.endSessionClose();
    }
  }

  Future<int> _logoutAllDevices(DioClient client) async {
    final tokenStore = ref.read(tokenStoreProvider);
    await client.awaitPendingRefresh();
    final refreshToken = await tokenStore.readRefreshToken();
    if (refreshToken == null) {
      throw const ApiException(
        statusCode: 401,
        message: 'Session introuvable sur cet appareil',
        code: ErrorCodes.refreshTokenInvalid,
      );
    }
    final revoked = await ref
        .read(authApiProvider)
        .logout(refreshToken: refreshToken, allDevices: true);
    // Zéro session fermée = rien n'a été coupé côté serveur (session déjà
    // remplacée, par exemple). Annoncer « tout est déconnecté » serait un
    // mensonge dangereux en cas de vol : on garde la session et on le dit (N7).
    if (revoked < 1) {
      // Pas de code serveur inventé : `refreshTokenInvalid` serait traduit en
      // « Session expirée, reconnectez-vous » et marquerait la session comme à
      // refaire, alors qu'elle est justement CONSERVÉE (revue finale, point 4).
      throw const ApiException(
        statusCode: 409,
        message: 'Aucune session n’a pu être fermée. Réessayez.',
      );
    }
    await _endSession(switch (state.value) {
      AuthSignedIn(:final user) => user.id,
      _ => null,
    }, 'Toutes vos sessions ont été fermées.');
    return revoked;
  }

  /// Appelé par l'intercepteur Dio quand le refresh a définitivement échoué.
  Future<void> onSessionExpired() => _endSession(switch (state.value) {
    AuthSignedIn(:final user) => user.id,
    _ => null,
  }, 'Session expirée, reconnectez-vous');
}

final authControllerProvider = AsyncNotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
