import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/application/auth_controller.dart';
import '../../features/auth/presentation/change_password_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../ui/adaptive_shell.dart';

class AppRoutes {
  const AppRoutes._();
  static const login = '/login';
  static const changePassword = '/change-password';
  static const home = '/';
}

/// Décide de la redirection à partir de l'état d'authentification.
///
/// Extrait du routeur pour être testable sans monter un widget :
/// c'est une règle de sécurité, elle mérite un test unitaire.
String? resolveRedirect({required AuthState? auth, required String location}) {
  // État encore inconnu (démarrage, ou hors-ligne au lancement) : on ne
  // redirige pas, l'écran de chargement reste affiché.
  if (auth == null || auth is AuthUnknown) return null;

  final isOnLogin = location == AppRoutes.login;
  final isOnChangePassword = location == AppRoutes.changePassword;

  if (auth is AuthSignedOut) {
    return isOnLogin ? null : AppRoutes.login;
  }

  if (auth is AuthSignedIn) {
    // Mot de passe temporaire : le serveur refuse TOUT le reste (403
    // PASSWORD_CHANGE_REQUIRED). Inutile de laisser naviguer ailleurs.
    if (auth.mustChangePassword) {
      return isOnChangePassword ? null : AppRoutes.changePassword;
    }
    if (isOnLogin || isOnChangePassword) return AppRoutes.home;
  }

  return null;
}

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.home,
    redirect: (context, state) => resolveRedirect(
      auth: ref.read(authControllerProvider).value,
      location: state.matchedLocation,
    ),
    // Re-évalue les redirections dès que la session change.
    refreshListenable: _AuthRefreshNotifier(ref),
    routes: [
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.changePassword,
        builder: (context, state) => const ChangePasswordScreen(),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const AdaptiveShell(),
      ),
    ],
  );
});

/// Pont Riverpod → go_router : notifie le routeur à chaque changement de session.
class _AuthRefreshNotifier extends ChangeNotifier {
  _AuthRefreshNotifier(Ref ref) {
    ref.listen(authControllerProvider, (_, _) => notifyListeners());
  }
}
