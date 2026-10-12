import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_api.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';

import 'support/fakes.dart';

class _TiersApi extends CatalogApi {
  _TiersApi() : super(Dio());

  bool offline = false;

  @override
  Future<List<PriceTier>> priceTiers() async {
    if (offline) {
      throw const ApiException(statusCode: 0, message: 'hors ligne');
    }
    return const [
      PriceTier(id: 'detail', code: 'DETAIL', name: 'Détail', isDefault: true),
    ];
  }
}

void main() {
  // Retour terrain du 2026-10-11 : hors ligne, la vente perdait le tarif par
  // défaut (tout produit « sans prix », encaissement bloqué).
  test('tarifs : lus en ligne, mémorisés, rendus hors ligne', () async {
    final api = _TiersApi();
    final container = ProviderContainer(
      // Pas de nouvel essai automatique : l'erreur doit se voir tout de suite.
      retry: (_, _) => null,
      overrides: [
        catalogApiProvider.overrideWithValue(api),
        localSettingsStoreProvider.overrideWithValue(MemorySettingsStore()),
      ],
    );
    addTearDown(container.dispose);

    final online = await container.read(priceTiersProvider.future);
    expect(online.single.isDefault, isTrue);

    api.offline = true;
    container.invalidate(priceTiersProvider);
    final offline = await container.read(priceTiersProvider.future);
    expect(offline.single.id, 'detail');
    expect(offline.single.isDefault, isTrue);
  });

  test('tarifs jamais lus et hors ligne : l’erreur remonte', () async {
    final api = _TiersApi()..offline = true;
    final container = ProviderContainer(
      // Pas de nouvel essai automatique : l'erreur doit se voir tout de suite.
      retry: (_, _) => null,
      overrides: [
        catalogApiProvider.overrideWithValue(api),
        localSettingsStoreProvider.overrideWithValue(MemorySettingsStore()),
      ],
    );
    addTearDown(container.dispose);
    // Provider auto-libéré : un écouteur le garde en vie pendant la lecture.
    final sub = container.listen(priceTiersProvider, (_, _) {});
    addTearDown(sub.close);
    await expectLater(
      container.read(priceTiersProvider.future),
      throwsA(isA<ApiException>()),
    );
  });
}
