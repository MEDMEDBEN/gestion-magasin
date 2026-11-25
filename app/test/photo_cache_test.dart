import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/data/local/photo_cache.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_api.dart';

/// Serveur injoignable : toute photo demandée échoue.
class _Offline extends CatalogApi {
  _Offline() : super(Dio());
  int calls = 0;

  @override
  Future<Uint8List> imageBytes(String productId) async {
    calls++;
    throw const ApiException(statusCode: 0, message: 'Serveur injoignable');
  }
}

void main() {
  late Directory dir;
  late PhotoCache cache;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('photos-test');
    cache = PhotoCache(root: () async => dir);
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  // 2026-11-25 : l'app installée garde les photos sur le poste.
  test('écrite, relue ; remplacée par une nouvelle ; tout vidé', () async {
    final a = Uint8List.fromList([1, 2]);
    final b = Uint8List.fromList([3, 4]);
    expect(await cache.read('p1', 'products/p1/a.jpg'), isNull);

    await cache.write('p1', 'products/p1/a.jpg', a);
    expect(await cache.read('p1', 'products/p1/a.jpg'), a);

    // Nouvelle photo : l'ancienne est effacée du poste.
    await cache.write('p1', 'products/p1/b.jpg', b);
    expect(await cache.read('p1', 'products/p1/b.jpg'), b);
    expect(await cache.read('p1', 'products/p1/a.jpg'), isNull);

    await cache.clear();
    expect(await cache.read('p1', 'products/p1/b.jpg'), isNull);
  });

  test('une clé malformée ne sort pas du dossier des photos', () async {
    await cache.write('../x', '../../evil.jpg', Uint8List.fromList([9]));
    final written = dir
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path);
    expect(written, everyElement(startsWith(dir.path)));
    expect(written, isNotEmpty);
  });

  test(
    'hors ligne : la photo du poste s’affiche, sans appel serveur',
    () async {
      await cache.write('p1', 'products/p1/a.jpg', Uint8List.fromList([7]));
      final api = _Offline();
      final container = ProviderContainer(
        overrides: [
          catalogApiProvider.overrideWithValue(api),
          photoCacheProvider.overrideWithValue(cache),
        ],
      );
      addTearDown(container.dispose);
      const key = (productId: 'p1', imageKey: 'products/p1/a.jpg');

      final sub = container.listen(productImageProvider(key), (_, _) {});
      expect(await container.read(productImageProvider(key).future), [7]);
      expect(api.calls, 0);
      sub.close();
    },
  );
}
