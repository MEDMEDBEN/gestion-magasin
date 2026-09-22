import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/features/auth/application/auth_controller.dart';
import 'package:gestion_magasin/features/auth/data/auth_api.dart';

import 'support/fakes.dart';

/// Transitions de session pilotées par `AuthController` — sans réseau ni
/// stockage natif (faux AuthApi, stockage de tokens en mémoire).
void main() {
  late FakeAuthApi api;
  late MemoryTokenStore tokens;
  late ProviderContainer container;

  setUp(() async {
    api = FakeAuthApi();
    tokens = MemoryTokenStore();
    container = ProviderContainer(
      overrides: [
        authApiProvider.overrideWithValue(api),
        tokenStoreProvider.overrideWithValue(tokens),
        documentCacheProvider.overrideWithValue(MemoryDocumentCache()),
      ],
    );
    addTearDown(container.dispose);
    // Session restaurée depuis le refresh token stocké.
    expect(
      await container.read(authControllerProvider.future),
      isA<AuthSignedIn>(),
    );
  });

  AuthController controller() =>
      container.read(authControllerProvider.notifier);

  group('déconnecter TOUS les appareils (audit I3)', () {
    test('un échec REMONTE, et la session locale est conservée', () async {
      api.logoutFailure = const ApiException(
        statusCode: 0,
        message: 'Serveur injoignable',
      );

      await expectLater(
        controller().logoutAllDevices(),
        throwsA(isA<ApiException>()),
      );

      // L'utilisateur ne doit pas croire son téléphone volé déconnecté.
      expect(container.read(authControllerProvider).value, isA<AuthSignedIn>());
      expect(tokens.refresh, 'refresh-1');
    });

    test(
      'ZÉRO session fermée côté serveur = échec, pas un succès (N7)',
      () async {
        api.allDevicesRevoked = 0;

        final error = await controller().logoutAllDevices().then<ApiException?>(
          (_) => null,
          onError: (Object e) => e as ApiException,
        );
        expect(error, isNotNull);
        // Le message affiché dit la vérité, et la session n'est pas à refaire.
        expect(error!.userMessage, contains('Aucune session'));
        expect(error.requiresRelogin, isFalse);

        // Annoncer « tout est déconnecté » alors que rien ne l'a été serait un
        // mensonge dangereux en cas de vol.
        expect(
          container.read(authControllerProvider).value,
          isA<AuthSignedIn>(),
        );
        expect(tokens.refresh, 'refresh-1');
      },
    );

    test('un succès ferme la session locale et le dit', () async {
      final revoked = await controller().logoutAllDevices();

      expect(revoked, 3);
      expect(api.logoutCalls, [true]);
      final state = container.read(authControllerProvider).value;
      expect(state, isA<AuthSignedOut>());
      expect(
        (state! as AuthSignedOut).message,
        contains('Toutes vos sessions'),
      );
      expect(tokens.refresh, isNull);
    });
  });

  test('déconnexion simple : au mieux, même hors ligne', () async {
    api.logoutFailure = const ApiException(
      statusCode: 0,
      message: 'hors ligne',
    );

    await controller().logout();

    expect(container.read(authControllerProvider).value, isA<AuthSignedOut>());
    expect(tokens.refresh, isNull);
    expect(api.logoutCalls, [false]);
  });

  group('changement de mot de passe (revue C9)', () {
    test('ne fait JAMAIS passer la session en chargement', () async {
      final states = <AsyncValue<AuthState>>[];
      container.listen(authControllerProvider, (_, next) => states.add(next));

      await controller().changePassword(
        currentPassword: 'Ancien1234',
        newPassword: 'Nouveau1234',
      );

      expect(states.where((s) => s.isLoading), isEmpty);
      expect(states.last.value, isA<AuthSignedIn>());
      // Tokens NEUFS stockés : sinon déconnexion juste après le changement.
      expect(tokens.refresh, 'refresh-2');
    });

    test('un refus remonte à l’écran sans toucher à la session', () async {
      api.changePasswordFailure = const ApiException(
        statusCode: 403,
        message: 'Mot de passe actuel incorrect',
        code: 'CURRENT_PASSWORD_INVALID',
      );
      final states = <AsyncValue<AuthState>>[];
      container.listen(authControllerProvider, (_, next) => states.add(next));

      await expectLater(
        controller().changePassword(
          currentPassword: 'x',
          newPassword: 'Nouveau1234',
        ),
        throwsA(isA<ApiException>()),
      );

      expect(states, isEmpty);
      expect(tokens.refresh, 'refresh-1');
    });
  });
}
