import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  @override
  Future<AuthState> build() async => _restoreSession();

  /// Session persistante : si un refresh token valide existe, l'utilisateur
  /// n'a pas à ressaisir son mot de passe (spec §2bis).
  Future<AuthState> _restoreSession() async {
    final tokenStore = ref.read(tokenStoreProvider);
    final refreshToken = await tokenStore.readRefreshToken();
    if (refreshToken == null) return const AuthSignedOut();

    try {
      // `/auth/me` déclenche au besoin le refresh automatique de l'intercepteur.
      final user = await ref.read(authApiProvider).me();
      return AuthSignedIn(user);
    } on ApiException catch (error) {
      // Hors-ligne au lancement : on ne déconnecte SURTOUT pas, sinon l'app
      // devient inutilisable sur le terrain et la file de mutations en attente
      // devient inaccessible. L'utilisateur pourra réessayer.
      if (error.isOffline) return const AuthUnknown();

      // Panne serveur passagère : la session reste valide, on n'efface rien.
      if (error.statusCode >= 500) return const AuthUnknown();

      // Session réellement finie (401, refresh révoqué/expiré, compte désactivé).
      if (error.statusCode == 401 || error.requiresRelogin) {
        await tokenStore.clear();
        return AuthSignedOut(message: error.userMessage);
      }

      // 403 : la session est techniquement valide mais le compte ne peut pas
      // utiliser l'app (aucun rôle attribué, par exemple). Le renvoyer en
      // « non résolu » afficherait « serveur injoignable » et un bouton
      // Réessayer qui boucle. On le dit clairement, sans effacer les tokens.
      if (error.statusCode == 403) {
        return AuthSignedOut(message: error.userMessage);
      }

      return const AuthUnknown();
    }
  }

  Future<void> login({
    required String identifier,
    required String password,
  }) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final deviceId = await ref.read(deviceIdProvider.future);
      final session = await ref.read(authApiProvider).login(
            identifier: identifier,
            password: password,
            deviceId: deviceId,
          );
      await ref.read(tokenStoreProvider).saveTokens(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
          );
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
    final deviceId = await ref.read(deviceIdProvider.future);
    final session = await ref.read(authApiProvider).changePassword(
          currentPassword: currentPassword,
          newPassword: newPassword,
          deviceId: deviceId,
        );
    await ref.read(tokenStoreProvider).saveTokens(
          accessToken: session.accessToken,
          refreshToken: session.refreshToken,
        );
    state = AsyncValue.data(AuthSignedIn(session.user));
  }

  /// Déconnexion de CET appareil. Au mieux : hors-ligne, la session serveur ne
  /// peut pas être fermée tout de suite, mais la session locale l'est — et le
  /// refresh token, jamais réutilisé, expirera.
  Future<void> logout() async {
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
    } finally {
      client.endSessionClose();
    }
    state = const AsyncValue.data(AuthSignedOut());
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
    await tokenStore.clear();
    state = const AsyncValue.data(
      AuthSignedOut(message: 'Toutes vos sessions ont été fermées.'),
    );
    return revoked;
  }

  /// Appelé par l'intercepteur Dio quand le refresh a définitivement échoué.
  Future<void> onSessionExpired() async {
    await ref.read(tokenStoreProvider).clear();
    state = const AsyncValue.data(
      AuthSignedOut(message: 'Session expirée, reconnectez-vous'),
    );
  }
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);
