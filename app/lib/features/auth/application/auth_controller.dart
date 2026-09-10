import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import '../../../data/models/auth_models.dart';

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
/// de passe imposé, déconnexion. Aucune logique de ce genre dans les widgets.
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

  /// Le serveur révoque toutes les sessions et renvoie des tokens neufs :
  /// on les stocke, sinon l'utilisateur serait déconnecté juste après avoir
  /// changé son mot de passe.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final session = await ref.read(authApiProvider).changePassword(
            currentPassword: currentPassword,
            newPassword: newPassword,
          );
      await ref.read(tokenStoreProvider).saveTokens(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
          );
      return AuthSignedIn(session.user);
    });
  }

  /// `allDevices` ferme TOUTES les sessions du compte (perte, vol, départ).
  Future<void> logout({bool allDevices = false}) async {
    final tokenStore = ref.read(tokenStoreProvider);
    final refreshToken = await tokenStore.readRefreshToken();
    try {
      await ref.read(authApiProvider).logout(
            refreshToken: refreshToken,
            allDevices: allDevices,
          );
    } on ApiException {
      // Hors-ligne : on ne peut pas révoquer côté serveur, mais on nettoie
      // localement — le token expirera de lui-même.
    }
    await tokenStore.clear();
    state = const AsyncValue.data(AuthSignedOut());
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
