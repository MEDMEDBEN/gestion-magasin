import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/file_export.dart';

/// Rend toujours la même réponse, sans réseau.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.status, this.body, [this.headers = const {}]);

  final int status;
  final List<int> body;
  final Map<String, List<String>> headers;
  RequestOptions? last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options;
    return ResponseBody.fromBytes(body, status, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('rend les octets et le nom annoncé, avec le format demandé', () async {
    final adapter = _Adapter(
      200,
      [1, 2, 3],
      {
        'content-disposition': ['attachment; filename="rapport-stock.pdf"'],
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;

    final file = await fetchExport(
      dio,
      '/reports/stock/export',
      ExportFormat.pdf,
    );

    expect(file.bytes, [1, 2, 3]);
    expect(file.filename, 'rapport-stock.pdf');
    expect(adapter.last!.queryParameters['format'], 'pdf');
  });

  /// En `bytes`, l'erreur arrive AUSSI en octets : sans décodage, le refus
  /// métier se lirait « Erreur inattendue du serveur ».
  test('un refus métier garde son code et son message', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter(
        400,
        utf8.encode(
          jsonEncode({
            'statusCode': 400,
            'message': 'Export trop volumineux',
            'code': 'EXPORT_TOO_LARGE',
          }),
        ),
        {
          'content-type': ['application/json'],
        },
      );

    await expectLater(
      fetchExport(dio, '/sales/export', ExportFormat.csv),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'EXPORT_TOO_LARGE')
            .having((e) => e.message, 'message', 'Export trop volumineux'),
      ),
    );
  });
}
