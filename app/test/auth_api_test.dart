import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/features/auth/data/auth_api.dart';

/// Audit M6 : le logout ne dépend JAMAIS d'un access token. S'il en joignait un
/// expiré, l'intercepteur rafraîchirait d'abord, et le logout révoquerait
/// l'ANCIEN refresh token en laissant le neuf vivant 90 jours.
class _Recorder implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{"revoked":1}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('le logout part SANS access token, le refresh token servant de preuve', () async {
    final adapter = _Recorder();
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
      ..httpClientAdapter = adapter
      // Même intercepteur de principe que le vrai client : il joint un token
      // sauf si la requête est marquée publique.
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.extra['skipAuth'] != true) {
              options.headers['Authorization'] = 'Bearer access-expire';
            }
            handler.next(options);
          },
        ),
      );

    final revoked = await AuthApi(dio).logout(refreshToken: 'refresh-courant');

    expect(revoked, 1);
    final request = adapter.requests.single;
    expect(request.headers.containsKey('Authorization'), isFalse);
    expect(request.data, {'refreshToken': 'refresh-courant', 'allDevices': false});
  });
}
