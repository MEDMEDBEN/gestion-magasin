import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/config/app_config.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/error/error_codes.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/document_cache.dart';
import 'package:gestion_magasin/data/local/token_store.dart';
import 'package:gestion_magasin/features/auth/application/auth_controller.dart';
import 'package:gestion_magasin/features/auth/data/auth_api.dart';

import 'support/fakes.dart';

/// Access token au format JWT portant le compte `sub` (signature factice :
/// l'app ne la vérifie jamais, le serveur si).
String jwtFor(String sub) {
  String part(Map<String, Object> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({'sub': sub})}.signature';
}

/// Ouvrir l'app SANS réseau : la fiche du compte gardée au dernier contact
/// avec le serveur ouvre la session hors ligne, 72 h au plus, et le serveur la
/// revérifie dès qu'il répond.
void main() {
  const offline = ApiException(statusCode: 0, message: 'Serveur injoignable');
  const outage = ApiException(statusCode: 503, message: 'panne');

  late FakeAuthApi api;
  late MemoryTokenStore tokens;
  late MemoryDocumentCache documents;
  late ProviderContainer container;

  setUp(() {
    api = FakeAuthApi();
    // Tokens du compte « me » : celui de `authUser()`.
    tokens = MemoryTokenStore(access: jwtFor('me'));
    documents = MemoryDocumentCache();
  });

  Future<AuthState> start() {
    container = ProviderContainer(
      overrides: [
        authApiProvider.overrideWithValue(api),
        tokenStoreProvider.overrideWithValue(tokens),
        documentCacheProvider.overrideWithValue(documents),
      ],
    );
    addTearDown(container.dispose);
    return container.read(authControllerProvider.future);
  }

  AuthState? current() => container.read(authControllerProvider).value;

  /// Fiche gardée comme après un démarrage en ligne, `age` plus tôt.
  void remembered({
    Duration age = const Duration(hours: 1),
    bool mustChangePassword = false,
    String id = 'me',
  }) {
    tokens
      ..offlineUser = jsonEncode(
        authUser(
          id: id,
          fullName: 'Vendeur Hors Ligne',
        ).copyWith(mustChangePassword: mustChangePassword).toJson(),
      )
      ..serverContactAt = DateTime.now().toUtc().subtract(age);
  }

  test('en ligne : la fiche du compte est gardée pour plus tard', () async {
    expect(await start(), isA<AuthSignedIn>());
    expect(tokens.offlineUser, contains('Admin Principal'));
    expect(tokens.serverContactAt, isNotNull);
  });

  test('sans réseau, avec une fiche récente : l’app s’ouvre', () async {
    remembered();
    api.meFailure = offline;

    final state = await start();

    expect(state, isA<AuthSignedIn>());
    expect((state as AuthSignedIn).user.fullName, 'Vendeur Hors Ligne');
    // Rien n'est effacé : la session reste celle du serveur.
    expect(tokens.refresh, 'refresh-1');
    // L'instant est retenu contre une horloge reculée plus tard.
    expect(tokens.offlineSeen, isNotNull);
  });

  test('panne serveur (5xx) : même chose qu’hors ligne', () async {
    remembered();
    api.meFailure = outage;

    expect(await start(), isA<AuthSignedIn>());
  });

  group('pas d’ouverture hors ligne', () {
    setUp(() => api.meFailure = offline);

    test('fiche de plus de 72 h', () async {
      remembered(age: const Duration(hours: 73));
      expect(await start(), isA<AuthUnknown>());
    });

    test('jamais connecté sur cet appareil', () async {
      expect(await start(), isA<AuthUnknown>());
    });

    test('mot de passe temporaire', () async {
      remembered(mustChangePassword: true);
      expect(await start(), isA<AuthUnknown>());
    });

    test('fiche illisible (ancienne version)', () async {
      remembered();
      tokens.offlineUser = '{"pas":"une fiche"}';
      expect(await start(), isA<AuthUnknown>());
    });

    test('fiche d’un AUTRE compte que celui des tokens', () async {
      remembered(id: 'collegue');
      expect(await start(), isA<AuthUnknown>());
    });

    test('horloge reculée : le temps déjà vu compte toujours', () async {
      remembered(age: const Duration(hours: 1));
      // L'appareil a déjà vu un instant 72 h après le contact.
      tokens.offlineSeen = tokens.serverContactAt!.add(
        AppConfig.maxOfflineDuration + const Duration(minutes: 1),
      );
      expect(await start(), isA<AuthUnknown>());
    });
  });

  test(
    'session révoquée (401) : jamais de hors-ligne, retour au login',
    () async {
      remembered();
      api.meFailure = const ApiException(statusCode: 401, message: 'révoquée');

      expect(await start(), isA<AuthSignedOut>());
      expect(tokens.offlineUser, isNull);
    },
  );

  test('plus aucun rôle (403) au démarrage : la fiche est effacée', () async {
    remembered();
    api.meFailure = const ApiException(statusCode: 403, message: 'aucun rôle');

    expect(await start(), isA<AuthSignedOut>());
    // Plus rien n'ouvrira l'app hors ligne avec les anciens rôles…
    expect(tokens.offlineUser, isNull);
    // … mais la session reste : l'admin peut rendre un rôle.
    expect(tokens.refresh, 'refresh-1');
  });

  test('borne des 72 h', () {
    final contact = DateTime.utc(2026, 9, 29, 12);
    const max = AppConfig.maxOfflineDuration;
    bool allowed(DateTime now, [DateTime? seen]) =>
        AuthController.offlineStartAllowed(contact, now, lastSeen: seen);

    expect(allowed(contact), isTrue);
    expect(allowed(contact.add(max)), isTrue);
    expect(allowed(contact.add(max + const Duration(minutes: 1))), isFalse);
    // Horloge avant le dernier contact : refusé.
    expect(allowed(contact.subtract(const Duration(minutes: 1))), isFalse);
    // Horloge reculée APRÈS usage : l'instant le plus tardif vu fait foi.
    expect(
      allowed(
        contact.add(const Duration(hours: 1)),
        contact.add(max + const Duration(hours: 1)),
      ),
      isFalse,
    );
  });

  test('compte d’un token : lu sans signature, illisible = aucun', () {
    expect(AuthController.tokenSubject(jwtFor('abc')), 'abc');
    expect(AuthController.tokenSubject('access-1'), isNull);
    expect(AuthController.tokenSubject('a.%%%.c'), isNull);
    expect(AuthController.tokenSubject(null), isNull);
  });

  group('retour du serveur', () {
    setUp(() async {
      remembered();
      api.meFailure = offline;
      expect(await start(), isA<AuthSignedIn>());
      // Le réseau tombe (constaté par un appel), puis revient.
      container.read(serverReachableProvider.notifier).report(false);
    });

    Future<void> serverBack() async {
      container.read(serverReachableProvider.notifier).report(true);
      await pumpEventQueue();
    }

    test('la session est reconnue et les droits mis à jour', () async {
      api
        ..meFailure = null
        ..user = authUser(permissions: const ['user.manage', 'sale.credit']);

      await serverBack();

      final state = current()! as AuthSignedIn;
      expect(state.user.permissions, contains('sale.credit'));
      expect(tokens.offlineUser, contains('sale.credit'));
    });

    test(
      'compte désactivé entre-temps : retour au login, tout effacé',
      () async {
        await documents.save('me', DocumentKind.transfer, const [
          {'id': 't1'},
        ]);
        api.meFailure = const ApiException(
          statusCode: 403,
          message: 'Compte désactivé',
          code: ErrorCodes.accountDisabled,
        );

        await serverBack();

        expect(current(), isA<AuthSignedOut>());
        expect(tokens.refresh, isNull);
        expect(tokens.offlineUser, isNull);
        // Les documents du compte ne restent pas sur le poste partagé.
        expect(documents.byKind, isEmpty);
      },
    );

    test('plus aucun rôle (403) : retour au login', () async {
      api.meFailure = const ApiException(statusCode: 403, message: 'rôle');

      await serverBack();

      expect(current(), isA<AuthSignedOut>());
      expect(tokens.refresh, isNull);
    });

    test('hoquet (429) : on réessaie, la session continue', () async {
      api.meFailure = const ApiException(statusCode: 429, message: 'quota');
      await serverBack();
      expect(current(), isA<AuthSignedIn>());

      // Le hoquet passé, la session est bien reconnue.
      api
        ..meFailure = null
        ..user = authUser(fullName: 'Reconnu');
      container.read(serverReachableProvider.notifier).report(false);
      await serverBack();
      expect((current()! as AuthSignedIn).user.fullName, 'Reconnu');
    });

    test('toujours injoignable : la session hors ligne continue', () async {
      await serverBack();

      expect(current(), isA<AuthSignedIn>());
      expect(tokens.refresh, 'refresh-1');
    });

    test(
      'déconnexion pendant l’écriture de la fiche : reste déconnecté',
      () async {
        final gate = Completer<void>();
        tokens.beforeSaveOfflineUser = () => gate.future;
        api.meFailure = null;
        container.read(serverReachableProvider.notifier).report(true);
        await pumpEventQueue(); // `/auth/me` a répondu, la fiche s'écrit…

        await container.read(authControllerProvider.notifier).logout();
        gate.complete();
        await pumpEventQueue();

        // … la vérification, partie avant, ne rouvre pas la session.
        expect(current(), isA<AuthSignedOut>());
        expect(tokens.refresh, isNull);
      },
    );

    test('déconnexion pendant la vérification : rien n’est réécrit', () async {
      api.meFailure = null;
      container.read(serverReachableProvider.notifier).report(true);
      // Pas d'attente : la déconnexion passe pendant l'appel `/auth/me`.
      await container.read(authControllerProvider.notifier).logout();
      await pumpEventQueue();

      expect(current(), isA<AuthSignedOut>());
      expect(tokens.offlineUser, isNull);
    });
  });

  test('panne serveur au démarrage : le battement revérifie la session', () {
    fakeAsync((async) {
      remembered();
      api.meFailure = outage;
      AuthState? state;
      start().then((s) => state = s);
      async.flushMicrotasks();
      expect(state, isA<AuthSignedIn>());

      // Le serveur repart. Un 5xx n'a jamais fait « tomber » le réseau : seul
      // le battement peut revérifier.
      api
        ..meFailure = null
        ..user = authUser(fullName: 'Reconnu');
      async
        ..elapse(AppConfig.syncInterval)
        ..flushMicrotasks();

      expect((current()! as AuthSignedIn).user.fullName, 'Reconnu');
    });
  });

  test('en ligne : la fiche est relue au serveur toutes les heures', () {
    fakeAsync((async) {
      start();
      async.flushMicrotasks();
      api.user = authUser(permissions: const ['user.manage', 'sale.credit']);

      async
        ..elapse(const Duration(minutes: 59))
        ..flushMicrotasks();
      expect(tokens.offlineUser, isNot(contains('sale.credit')));

      async
        ..elapse(const Duration(minutes: 2))
        ..flushMicrotasks();
      expect(tokens.offlineUser, contains('sale.credit'));
    });
  });

  test('72 h dépassées app OUVERTE : retour à « serveur injoignable »', () {
    fakeAsync((async) {
      remembered();
      api.meFailure = offline;
      start();
      async.flushMicrotasks();
      expect(current(), isA<AuthSignedIn>());

      // Le temps passe : le dernier contact date maintenant de plus de 72 h.
      tokens.serverContactAt = DateTime.now().toUtc().subtract(
        AppConfig.maxOfflineDuration + const Duration(minutes: 1),
      );
      async
        ..elapse(AppConfig.syncInterval)
        ..flushMicrotasks();

      expect(current(), isA<AuthUnknown>());
      // Rien n'est effacé : la file et la session attendent le serveur.
      expect(tokens.refresh, 'refresh-1');
      expect(tokens.offlineUser, isNotNull);
    });
  });

  test('session refusée au démarrage : documents du compte purgés', () async {
    await documents.save('me', DocumentKind.transfer, const [
      {'id': 't1'},
    ]);
    api.meFailure = const ApiException(
      statusCode: 403,
      message: 'Compte désactivé',
      code: ErrorCodes.accountDisabled,
    );

    expect(await start(), isA<AuthSignedOut>());
    expect(documents.byKind, isEmpty);
  });

  test('vérification horaire PENDANT une déconnexion : reste déconnecté', () {
    fakeAsync((async) {
      start();
      async.flushMicrotasks();
      final logoutGate = Completer<void>();
      final meGate = Completer<void>();
      api
        ..beforeLogout = (() => logoutGate.future)
        ..beforeMe = (() => meGate.future);

      // La déconnexion attend le serveur…
      container.read(authControllerProvider.notifier).logout();
      async.flushMicrotasks();
      // … pendant que tombe la relecture horaire.
      async
        ..elapse(const Duration(hours: 1))
        ..flushMicrotasks();
      logoutGate.complete();
      async.flushMicrotasks();
      meGate.complete();
      async.flushMicrotasks();

      expect(current(), isA<AuthSignedOut>());
      expect(tokens.offlineUser, isNull);
    });
  });

  test(
    'vérification partie avant un changement de mot de passe : sans effet',
    () async {
      remembered();
      api.meFailure = offline;
      expect(await start(), isA<AuthSignedIn>());
      container.read(serverReachableProvider.notifier).report(false);

      final meGate = Completer<void>();
      api
        ..meFailure = null
        ..user = authUser(fullName: 'Ancien profil')
        ..beforeMe = (() => meGate.future);
      container.read(serverReachableProvider.notifier).report(true);
      await pumpEventQueue();

      api.user = authUser(fullName: 'Nouveau profil');
      await container
          .read(authControllerProvider.notifier)
          .changePassword(
            currentPassword: 'Ancien1234',
            newPassword: 'Nouv1234',
          );
      meGate.complete();
      await pumpEventQueue();

      expect((current()! as AuthSignedIn).user.fullName, 'Nouveau profil');
    },
  );

  test('déconnexion : la fiche gardée est effacée', () async {
    await start();
    await container.read(authControllerProvider.notifier).logout();

    expect(tokens.offlineUser, isNull);
    expect(tokens.serverContactAt, isNull);
  });

  group('TokenStore (stockage chiffré réel, simulé)', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('un renouvellement de tokens ne rajeunit PAS la fiche', () async {
      final store = TokenStore();
      await store.saveOfflineUser('{"id":"me"}');
      final contact = (await store.readOfflineUser())!.serverContactAt;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.saveTokens(accessToken: 'a', refreshToken: 'r');

      expect((await store.readOfflineUser())!.serverContactAt, contact);
    });

    test(
      'l’instant vu hors ligne ne recule jamais, effacé au logout',
      () async {
        final store = TokenStore();
        await store.saveOfflineUser('{"id":"me"}');
        await store.markOfflineSeen();
        final seen = (await store.readOfflineUser())!.lastSeen;
        expect(seen, isNotNull);

        await store.markOfflineSeen();
        expect(
          (await store.readOfflineUser())!.lastSeen!.isBefore(seen!),
          isFalse,
        );

        await store.clear();
        expect(await store.readOfflineUser(), isNull);
      },
    );
  });
}
