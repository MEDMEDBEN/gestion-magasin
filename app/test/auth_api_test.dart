import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/data/api/dio_client.dart';
import 'package:gestion_magasin/features/auth/data/auth_api.dart';

import 'support/fakes.dart';

/// Audit M6 + contre-revue N3 : testé avec le VRAI `DioClient` (et son vrai
/// intercepteur de refresh), pas une imitation. Le logout ne dépend JAMAIS d'un
/// access token : s'il en joignait un expiré, l'intercepteur rafraîchirait
/// d'abord, et le logout révoquerait l'ANCIEN refresh token en laissant le neuf
/// vivant 90 jours.
class _Recorder implements HttpClientAdapter {
  _Recorder({this.logoutStatus = 200, this.logoutBody = '{"revoked":1}'});

  final int logoutStatus;
  final String logoutBody;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final isLogout = options.path == '/auth/logout';
    return ResponseBody.fromString(
      isLogout ? logoutBody : '{"accessToken":"a2","refreshToken":"r2"}',
      isLogout ? logoutStatus : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late MemoryTokenStore tokens;
  var sessionExpired = 0;

  setUp(() {
    tokens = MemoryTokenStore(access: 'access-expire', refresh: 'refresh-courant');
    sessionExpired = 0;
  });

  AuthApi apiWith(_Recorder adapter) {
    final client = DioClient(
      tokenStore: tokens,
      onSessionExpired: () async => sessionExpired++,
      baseUrl: 'http://test.local/api',
    );
    client.dio.httpClientAdapter = adapter;
    return AuthApi(client.dio);
  }

  test('le logout part SANS access token, le refresh token servant de preuve', () async {
    final adapter = _Recorder();

    final revoked = await apiWith(adapter).logout(refreshToken: 'refresh-courant');

    expect(revoked, 1);
    final request = adapter.requests.single;
    // Le vrai intercepteur joint un token à toute requête non publique :
    // son absence prouve que la route est bien marquée publique.
    expect(request.headers.containsKey('Authorization'), isFalse);
    expect(request.data, {'refreshToken': 'refresh-courant', 'allDevices': false});
  });

  test('un 401 sur le logout ne déclenche AUCUN refresh', () async {
    final adapter = _Recorder(
      logoutStatus: 401,
      logoutBody: '{"statusCode":401,"code":"ACCESS_TOKEN_INVALID"}',
    );

    await expectLater(
      apiWith(adapter).logout(refreshToken: 'refresh-courant', allDevices: true),
      throwsA(isA<ApiException>()),
    );

    // Une seule requête : le logout. Aucune rotation déclenchée dans son dos,
    // aucun token modifié, aucune fin de session forcée.
    expect(adapter.requests.map((r) => r.path), ['/auth/logout']);
    expect(tokens.refresh, 'refresh-courant');
    expect(sessionExpired, 0);
  });
}
