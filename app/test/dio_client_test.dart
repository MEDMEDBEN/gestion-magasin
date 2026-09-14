import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/data/api/dio_client.dart';
import 'package:gestion_magasin/data/local/token_store.dart';

/// Stockage sécurisé en mémoire : le vrai plugin est natif, indisponible en test.
class _InMemorySecureStorage implements FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'Méthode non utilisée par les tests : ${invocation.memberName}',
      );
}

/// Simule une absence TOTALE de réponse sur le refresh (coupure réseau).
class _ThrowingRefreshAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/auth/refresh') {
      throw DioException.connectionTimeout(
        timeout: const Duration(seconds: 1),
        requestOptions: options,
      );
    }
    return _json({'code': 'ACCESS_TOKEN_INVALID'}, 401);
  }

  @override
  void close({bool force = false}) {}
}

/// Comme `_ScriptedAdapter`, mais la réponse à `/auth/refresh` n'arrive que
/// quand le test ouvre la barrière : permet d'agir PENDANT une rotation.
class _GatedRefreshAdapter implements HttpClientAdapter {
  final gate = Completer<void>();
  final refreshStarted = Completer<void>();
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path == '/auth/refresh') {
      refreshStarted.complete();
      await gate.future;
      return _json({'accessToken': 'access-neuf', 'refreshToken': 'refresh-neuf'}, 200);
    }
    if (options.path == '/auth/logout') return _json({'revoked': 1}, 200);
    return _json({'code': 'ACCESS_TOKEN_INVALID'}, 401);
  }

  @override
  void close({bool force = false}) {}
}

/// Intercepte les requêtes et rend des réponses scriptées, sans réseau.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.respond);

  final ResponseBody Function(RequestOptions options) respond;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, int status) =>
    ResponseBody.fromString(
      _encode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

String _encode(Map<String, dynamic> body) {
  final entries = body.entries
      .map((e) => '"${e.key}":${e.value is String ? '"${e.value}"' : e.value}')
      .join(',');
  return '{$entries}';
}

/// Aucune réponse du tout : serveur injoignable (coupure réseau).
class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'hors ligne',
    );
  }

  @override
  void close({bool force = false}) {}
}

/// L'intercepteur de refresh est la pièce la plus dangereuse du client :
/// une erreur y ferme la session de tout le monde, et coupe l'accès aux
/// ventes hors-ligne encore en file. Ces tests verrouillent son comportement.
void main() {
  late _InMemorySecureStorage storage;
  late TokenStore tokenStore;
  var sessionExpiredCalls = 0;

  setUp(() async {
    storage = _InMemorySecureStorage();
    tokenStore = TokenStore(storage);
    sessionExpiredCalls = 0;
    await tokenStore.saveTokens(
      accessToken: 'access-perime',
      refreshToken: 'refresh-valide',
    );
  });

  DioClient buildClient(_ScriptedAdapter adapter) {
    final client = DioClient(
      tokenStore: tokenStore,
      onSessionExpired: () async => sessionExpiredCalls++,
      baseUrl: 'http://test.local/api',
    );
    client.dio.httpClientAdapter = adapter;
    return client;
  }

  group('déconnexion PENDANT une rotation (contre-audit N8)', () {
    test('awaitPendingRefresh attend la fin de la rotation en cours', () async {
      final adapter = _GatedRefreshAdapter();
      final client = DioClient(
        tokenStore: tokenStore,
        onSessionExpired: () async => sessionExpiredCalls++,
        baseUrl: 'http://test.local/api',
      );
      client.dio.httpClientAdapter = adapter;

      unawaited(client.dio.get<void>('/products').catchError((_) => Response<void>(
            requestOptions: RequestOptions(),
          )));
      await adapter.refreshStarted.future;

      var waited = false;
      final waiting = client.awaitPendingRefresh().then((_) => waited = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(waited, isFalse, reason: 'ne doit pas rendre la main pendant la rotation');

      adapter.gate.complete();
      await waiting;
      // La déconnexion lira donc le token NEUF, pas celui qui vient de mourir.
      expect(await tokenStore.readRefreshToken(), 'refresh-neuf');
    });

    test('session quittée pendant la rotation : tokens neufs NON stockés, session neuve fermée', () async {
      final adapter = _GatedRefreshAdapter();
      final client = DioClient(
        tokenStore: tokenStore,
        onSessionExpired: () async => sessionExpiredCalls++,
        baseUrl: 'http://test.local/api',
      );
      client.dio.httpClientAdapter = adapter;

      final pending = client.dio.get<void>('/products').catchError((_) => Response<void>(
            requestOptions: RequestOptions(),
          ));
      await adapter.refreshStarted.future;

      // L'utilisateur se déconnecte localement pendant que la rotation voyage.
      storage.values.clear();
      adapter.gate.complete();
      await pending;

      // Ressusciter une session que l'utilisateur vient de quitter : interdit.
      expect(await tokenStore.readRefreshToken(), isNull);
      final logout = adapter.requests.where((r) => r.path == '/auth/logout').toList();
      expect(logout, hasLength(1));
      expect((logout.single.data as Map)['refreshToken'], 'refresh-neuf');
    });
  });

  test('pendant une fermeture de session, un 401 ne déclenche AUCUNE rotation (mineur 2)', () async {
    var refreshCalls = 0;
    final adapter = _ScriptedAdapter((options) {
      if (options.path == '/auth/refresh') {
        refreshCalls++;
        return _json({'accessToken': 'a', 'refreshToken': 'r'}, 200);
      }
      return _json({'code': 'ACCESS_TOKEN_INVALID'}, 401);
    });
    final client = buildClient(adapter);

    client.beginSessionClose();
    await expectLater(
      client.dio.get<Map<String, dynamic>>('/products'),
      throwsA(isA<DioException>()),
    );
    client.endSessionClose();

    expect(refreshCalls, 0);
    // Rien n'est effacé ni remplacé : la fermeture en cours s'en charge.
    expect(await tokenStore.readRefreshToken(), 'refresh-valide');
  });

  test('joint l’access token aux requêtes protégées', () async {
    final adapter = _ScriptedAdapter((_) => _json({'ok': true}, 200));
    final client = buildClient(adapter);

    await client.dio.get<Map<String, dynamic>>('/products');

    expect(
      adapter.requests.single.headers['Authorization'],
      'Bearer access-perime',
    );
  });

  test('rafraîchit sur 401 puis rejoue avec le NOUVEAU token', () async {
    final adapter = _ScriptedAdapter((options) {
      if (options.path == '/auth/refresh') {
        return _json({
          'accessToken': 'access-neuf',
          'refreshToken': 'refresh-neuf',
        }, 200);
      }
      final sent = options.headers['Authorization'];
      if (sent == 'Bearer access-neuf') return _json({'ok': true}, 200);
      return _json({'code': 'ACCESS_TOKEN_INVALID'}, 401);
    });
    final client = buildClient(adapter);

    final response = await client.dio.get<Map<String, dynamic>>('/products');

    expect(response.statusCode, 200);
    // La rotation doit être PERSISTÉE : l'ancien refresh est mort côté serveur.
    expect(await tokenStore.readRefreshToken(), 'refresh-neuf');
    expect(await tokenStore.readAccessToken(), 'access-neuf');
    expect(sessionExpiredCalls, 0);
  });

  test('deux 401 simultanés ne déclenchent qu’UN SEUL refresh', () async {
    var refreshCalls = 0;
    final adapter = _ScriptedAdapter((options) {
      if (options.path == '/auth/refresh') {
        refreshCalls++;
        return _json({
          'accessToken': 'access-neuf',
          'refreshToken': 'refresh-neuf',
        }, 200);
      }
      final sent = options.headers['Authorization'];
      if (sent == 'Bearer access-neuf') return _json({'ok': true}, 200);
      return _json({'code': 'ACCESS_TOKEN_INVALID'}, 401);
    });
    final client = buildClient(adapter);

    await Future.wait([
      client.dio.get<Map<String, dynamic>>('/products'),
      client.dio.get<Map<String, dynamic>>('/stock'),
      client.dio.get<Map<String, dynamic>>('/customers'),
    ]);

    // Deux rotations concurrentes feraient rejouer un token révoqué : le
    // serveur y verrait un vol et fermerait TOUTES les sessions.
    expect(refreshCalls, 1);
  });

  test('une panne serveur (500) sur le refresh CONSERVE la session', () async {
    final adapter = _ScriptedAdapter((options) {
      if (options.path == '/auth/refresh') {
        return _json({'message': 'panne'}, 500);
      }
      return _json({'code': 'ACCESS_TOKEN_INVALID'}, 401);
    });
    final client = buildClient(adapter);

    await expectLater(
      client.dio.get<Map<String, dynamic>>('/products'),
      throwsA(isA<DioException>()),
    );

    // Effacer ici déconnecterait l'appareil sur un simple hoquet, et couperait
    // l'accès aux mutations hors-ligne encore en file.
    expect(await tokenStore.readRefreshToken(), 'refresh-valide');
    expect(sessionExpiredCalls, 0);
  });

  test('un quota dépassé (429) sur le refresh CONSERVE la session', () async {
    final adapter = _ScriptedAdapter((options) {
      if (options.path == '/auth/refresh') {
        return _json({'message': 'trop de tentatives'}, 429);
      }
      return _json({'code': 'ACCESS_TOKEN_INVALID'}, 401);
    });
    final client = buildClient(adapter);

    await expectLater(
      client.dio.get<Map<String, dynamic>>('/products'),
      throwsA(isA<DioException>()),
    );

    expect(await tokenStore.readRefreshToken(), 'refresh-valide');
    expect(sessionExpiredCalls, 0);
  });

  test('un refresh révoqué (401) ferme la session', () async {
    final adapter = _ScriptedAdapter((options) {
      if (options.path == '/auth/refresh') {
        return _json({'code': 'REFRESH_TOKEN_REVOKED'}, 401);
      }
      return _json({'code': 'ACCESS_TOKEN_INVALID'}, 401);
    });
    final client = buildClient(adapter);

    await expectLater(
      client.dio.get<Map<String, dynamic>>('/products'),
      throwsA(isA<DioException>()),
    );

    expect(await tokenStore.readRefreshToken(), isNull);
    expect(await tokenStore.readAccessToken(), isNull);
    expect(sessionExpiredCalls, 1);
  });

  test('un échec de login ne déclenche AUCUN refresh', () async {
    var refreshCalls = 0;
    final adapter = _ScriptedAdapter((options) {
      if (options.path == '/auth/refresh') {
        refreshCalls++;
        return _json({'accessToken': 'a', 'refreshToken': 'b'}, 200);
      }
      return _json({'code': 'INVALID_CREDENTIALS'}, 401);
    });
    final client = buildClient(adapter);

    await expectLater(
      client.dio.post<Map<String, dynamic>>(
        '/auth/login',
        data: {'identifier': 'x', 'password': 'y'},
        options: Options(extra: {'skipAuth': true}),
      ),
      throwsA(isA<DioException>()),
    );

    expect(refreshCalls, 0);
    expect(await tokenStore.readRefreshToken(), 'refresh-valide');
  });

  test('aucune réponse au refresh ⇒ session fermée (choix délibéré)', () async {
    // Cas AMBIGU : la rotation a peut-être abouti côté serveur et seule la
    // réponse s'est perdue. Réessayer rejouerait un token peut-être révoqué,
    // le serveur y verrait un VOL et fermerait TOUTES les sessions de
    // l'utilisateur. On préfère un re-login sur ce seul appareil.
    // NE PAS transformer ce cas en retry sans revoir la détection de vol serveur.
    final client = DioClient(
      tokenStore: tokenStore,
      onSessionExpired: () async => sessionExpiredCalls++,
      baseUrl: 'http://test.local/api',
    );
    client.dio.httpClientAdapter = _ThrowingRefreshAdapter();

    await expectLater(
      client.dio.get<Map<String, dynamic>>('/products'),
      throwsA(isA<DioException>()),
    );

    expect(await tokenStore.readRefreshToken(), isNull);
    expect(sessionExpiredCalls, 1);
  });

  test('un échec passager n’est pas martelé (fenêtre de silence)', () async {
    var refreshCalls = 0;
    final adapter = _ScriptedAdapter((options) {
      if (options.path == '/auth/refresh') {
        refreshCalls++;
        return _json({'message': 'panne'}, 500);
      }
      return _json({'code': 'ACCESS_TOKEN_INVALID'}, 401);
    });
    final client = buildClient(adapter);

    for (var i = 0; i < 4; i++) {
      await client.dio
          .get<Map<String, dynamic>>('/products')
          .catchError((Object _) => Response<Map<String, dynamic>>(
                requestOptions: RequestOptions(),
              ));
    }

    // `/auth/refresh` est throttlé côté serveur : le marteler brûlerait le quota.
    expect(refreshCalls, 1);
  });

  test('ne boucle pas si la requête rejouée échoue encore', () async {
    var protectedCalls = 0;
    final adapter = _ScriptedAdapter((options) {
      if (options.path == '/auth/refresh') {
        return _json({
          'accessToken': 'access-neuf',
          'refreshToken': 'refresh-neuf',
        }, 200);
      }
      protectedCalls++;
      return _json({'code': 'ACCESS_TOKEN_INVALID'}, 401);
    });
    final client = buildClient(adapter);

    await expectLater(
      client.dio.get<Map<String, dynamic>>('/products'),
      throwsA(isA<DioException>()),
    );

    // Une tentative initiale + un seul rejeu, pas une boucle infinie.
    expect(protectedCalls, 2);
  });

  group('joignabilité du serveur (indicateur « Hors ligne »)', () {
    DioClient reporting(HttpClientAdapter adapter, List<bool> reports) {
      final client = DioClient(
        tokenStore: tokenStore,
        onSessionExpired: () async {},
        onReachability: reports.add,
        baseUrl: 'http://test.local/api',
      );
      client.dio.httpClientAdapter = adapter;
      return client;
    }

    test('une réponse, même en erreur, prouve que le serveur est joignable', () async {
      final reports = <bool>[];
      final client = reporting(
        _ScriptedAdapter((_) => _json({'code': 'NOT_FOUND'}, 404)),
        reports,
      );

      await expectLater(client.dio.get<void>('/inconnu'), throwsA(isA<DioException>()));
      await client.dio.get<void>('/ok').catchError((_) => Response<void>(
            requestOptions: RequestOptions(),
          ));

      expect(reports, everyElement(isTrue));
    });

    test('aucune réponse signale un serveur injoignable', () async {
      final reports = <bool>[];
      final client = reporting(_OfflineAdapter(), reports);

      await expectLater(client.dio.get<void>('/products'), throwsA(isA<DioException>()));

      expect(reports, [false]);
    });
  });
}
