import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/data/local/photo_cache.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_api.dart';
import 'package:gestion_magasin/features/catalog/presentation/product_photo.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';

/// Photo qui échoue la première fois, puis réussit.
class _FlakyPhotos extends CatalogApi {
  _FlakyPhotos() : super(Dio());
  int calls = 0;

  @override
  Future<Uint8List> imageBytes(String productId) async {
    calls++;
    if (calls == 1) {
      throw const ApiException(statusCode: 429, message: 'Trop de requêtes');
    }
    return Uint8List.fromList([1, 2, 3]);
  }
}

void main() {
  thumbnailTests();
  // 2026-11-25 : des centaines de photos d'un coup bouchaient la connexion
  // (« hors ligne ») — au plus 4 à la fois, les autres attendent leur tour.
  test('au plus 4 téléchargements à la fois, tous finissent', () async {
    final gate = DownloadGate(4);
    var running = 0;
    var peak = 0;
    final done = await Future.wait([
      for (var i = 0; i < 30; i++)
        gate.run(() async {
          running++;
          peak = running > peak ? running : peak;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          running--;
          return i;
        }),
    ]);
    expect(peak, 4);
    expect(done, List.generate(30, (i) => i));
  });

  test('une erreur libère sa place', () async {
    final gate = DownloadGate(1);
    await expectLater(
      gate.run<void>(() async => throw StateError('x')),
      throwsStateError,
    );
    expect(await gate.run(() async => 'ok'), 'ok');
  });

  // Une photo refusée (429…) n'est pas gardée en erreur : elle est
  // redemandée (nouvel essai automatique), puis gardée une fois reçue.
  test('photo en échec : redemandée, puis gardée', () async {
    final api = _FlakyPhotos();
    final container = ProviderContainer(
      overrides: [catalogApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    const key = (productId: 'p1', imageKey: 'k1');

    final sub = container.listen(productImageProvider(key), (_, _) {});
    expect(await container.read(productImageProvider(key).future), [1, 2, 3]);
    expect(api.calls, 2);
    sub.close();
    await Future<void>.delayed(Duration.zero);
    // Gardée : pas de nouveau téléchargement.
    expect(await container.read(productImageProvider(key).future), [1, 2, 3]);
    expect(api.calls, 2);
  });
}

/// Rien sur le poste (le disque ne répond pas dans le temps simulé).
class _NoCache extends PhotoCache {
  @override
  Future<Uint8List?> read(String productId, String imageKey) async => null;

  @override
  Future<void> write(String productId, String imageKey, Uint8List b) async {}
}

/// Photo qui n'arrive que quand le test le décide.
class _SlowPhotos extends CatalogApi {
  _SlowPhotos() : super(Dio());
  final pending = Completer<Uint8List>();

  @override
  Future<Uint8List> imageBytes(String productId) => pending.future;
}

void thumbnailTests() {
  // 2026-11-25 : pendant le chargement, une ANIMATION — jamais « indisponible »
  // (l'utilisateur croyait que la photo n'existait pas).
  testWidgets(
    'vignette : « en chargement », puis « indisponible » si absente',
    (tester) async {
      final api = _SlowPhotos();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogApiProvider.overrideWithValue(api),
            photoCacheProvider.overrideWithValue(_NoCache()),
          ],
          child: MaterialApp(
            theme: AppTheme.desktop(dark: true),
            home: Scaffold(
              body: ProductThumbnail(
                product: product(
                  id: 'p1',
                ).copyWith(imageKey: 'products/p1/a.jpg'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('photo-chargement')), findsOneWidget);
      expect(find.byTooltip('Photo indisponible'), findsNothing);

      // Pas de photo au serveur (404) : là seulement, « indisponible ».
      api.pending.completeError(
        const ApiException(statusCode: 404, message: 'Pas de photo'),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('photo-chargement')), findsNothing);
      expect(find.byTooltip('Photo indisponible'), findsOneWidget);
    },
  );
}
