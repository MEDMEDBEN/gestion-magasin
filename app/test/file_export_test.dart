import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

  test('fenêtre des exports : N jours, aujourd’hui compris', () {
    final window = recentWindow(90, now: DateTime(2026, 9, 26, 23, 59));
    expect(window.to, '2026-09-26');
    expect(window.from, '2026-06-29');
  });

  /// Le nom annoncé par le serveur finit sur le disque : frontière de confiance.
  test(
    'nom de fichier : jamais de chemin, de caractère interdit ou réservé',
    () {
      String name(String raw) =>
          exportFilename('attachment; filename="$raw"', fallback: 'export.csv');
      expect(
        name('ventes_2026-09-01_2026-09-30.csv'),
        'ventes_2026-09-01_2026-09-30.csv',
      );
      expect(name('../../x.csv'), 'export.csv');
      expect(name('a/b.csv'), 'a_b.csv');
      expect(name('a\u0007b.csv'), 'a_b.csv');
      expect(name('rapport.csv. '), 'rapport.csv');
      expect(name('CON.csv'), 'export.csv');
      expect(name('nul'), 'export.csv');
      expect(exportFilename(null, fallback: 'export.pdf'), 'export.pdf');
    },
  );

  test('enregistrement : un fichier existant n’est jamais écrasé', () async {
    final dir = await Directory.systemTemp.createTemp('export_test');
    addTearDown(() => dir.delete(recursive: true));
    final file = ExportedFile(Uint8List.fromList([1]), 'stock.csv');

    final first = await saveWithoutOverwrite(dir, file);
    final second = await saveWithoutOverwrite(
      dir,
      ExportedFile(Uint8List.fromList([2]), 'stock.csv'),
    );

    expect(p.basename(first), 'stock.csv');
    expect(p.basename(second), 'stock (2).csv');
    expect(await File(first).readAsBytes(), [1]);
    expect(await File(second).readAsBytes(), [2]);
  });
}
