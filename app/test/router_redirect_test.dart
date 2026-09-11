import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/router/app_router.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/auth/application/auth_controller.dart';

AuthUser _user({bool mustChangePassword = false, List<String>? roles}) {
  return AuthUser(
    id: 'u1',
    email: 'vendeur@magasin.dz',
    phone: null,
    fullName: 'Vendeur Test',
    roles: roles ?? const ['VENDEUR'],
    permissions: const ['sale.create'],
    mustChangePassword: mustChangePassword,
  );
}

/// La redirection est une règle de SÉCURITÉ : un mot de passe temporaire doit
/// verrouiller l'app comme le serveur verrouille l'API (CLAUDE.md règle 14).
void main() {
  group('non authentifié', () {
    test('est renvoyé vers le login depuis n’importe où', () {
      expect(
        resolveRedirect(auth: const AuthSignedOut(), location: '/'),
        AppRoutes.login,
      );
    });

    test('reste sur le login sans boucler', () {
      expect(
        resolveRedirect(
          auth: const AuthSignedOut(),
          location: AppRoutes.login,
        ),
        isNull,
      );
    });
  });

  group('mot de passe temporaire', () {
    test('est forcé vers le changement de mot de passe', () {
      expect(
        resolveRedirect(
          auth: AuthSignedIn(_user(mustChangePassword: true)),
          location: '/',
        ),
        AppRoutes.changePassword,
      );
    });

    test('ne peut pas revenir au login pour contourner', () {
      expect(
        resolveRedirect(
          auth: AuthSignedIn(_user(mustChangePassword: true)),
          location: AppRoutes.login,
        ),
        AppRoutes.changePassword,
      );
    });

    test('reste sur l’écran de changement sans boucler', () {
      expect(
        resolveRedirect(
          auth: AuthSignedIn(_user(mustChangePassword: true)),
          location: AppRoutes.changePassword,
        ),
        isNull,
      );
    });
  });

  group('authentifié et mot de passe changé', () {
    test('accède normalement à l’accueil', () {
      expect(
        resolveRedirect(auth: AuthSignedIn(_user()), location: '/'),
        isNull,
      );
    });

    test('est renvoyé à l’accueil s’il retourne sur le login', () {
      expect(
        resolveRedirect(
          auth: AuthSignedIn(_user()),
          location: AppRoutes.login,
        ),
        AppRoutes.home,
      );
    });

    test('ne peut plus rouvrir le changement de mot de passe imposé', () {
      expect(
        resolveRedirect(
          auth: AuthSignedIn(_user()),
          location: AppRoutes.changePassword,
        ),
        AppRoutes.home,
      );
    });
  });

  group('état indéterminé', () {
    test('ne redirige pas tant que la session n’est pas résolue', () {
      expect(resolveRedirect(auth: null, location: '/'), isNull);
      expect(
        resolveRedirect(auth: const AuthUnknown(), location: '/'),
        isNull,
        reason: 'hors-ligne au lancement ne doit pas déconnecter',
      );
    });
  });
}
