import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_repository.dart';
import 'package:gestion_magasin/features/sales/data/sales_api.dart';
import 'package:gestion_magasin/features/sales/data/sales_models.dart';
import 'package:gestion_magasin/features/sales/presentation/sales_screen.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

/// Revue générale B3 : le catalogue local se met à jour à la CONNEXION et à
/// l'entrée en Vente — plus seulement en ouvrant l'écran Catalogue.
class _CountingRepository implements CatalogRepository {
  int pulls = 0;

  @override
  Future<void> pull() async => pulls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _User extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? id) => state = id;
}

final _userProvider = NotifierProvider<_User, String?>(_User.new);

class _NoCashApi extends SalesApi {
  _NoCashApi() : super(Dio());
  @override
  Future<CashSession?> currentCashSession() async => null;
}

void main() {
  test('synchro lancée à chaque connexion, jamais sans compte', () async {
    final repo = _CountingRepository();
    final container = ProviderContainer(
      overrides: [
        catalogRepositoryProvider.overrideWithValue(repo),
        currentUserIdProvider.overrideWith((ref) => ref.watch(_userProvider)),
      ],
    );
    addTearDown(container.dispose);
    // La coquille écoute le provider pendant toute la session.
    container.listen(catalogSyncProvider, (_, _) {});

    await container.read(catalogSyncProvider.future);
    expect(repo.pulls, 0, reason: 'personne n’est connecté');

    container.read(_userProvider.notifier).set('vendeur-1');
    await container.read(catalogSyncProvider.future);
    expect(repo.pulls, 1);

    // Poste partagé : un autre compte se connecte → nouvelle synchro.
    container.read(_userProvider.notifier).set('vendeur-2');
    await container.read(catalogSyncProvider.future);
    expect(repo.pulls, 2);
  });

  testWidgets('entrée en Vente : le catalogue est relu même déjà synchronisé', (
    tester,
  ) async {
    useScreenSize(tester, const Size(500, 1200));
    final repo = _CountingRepository();
    final container = ProviderContainer(
      overrides: [
        catalogRepositoryProvider.overrideWithValue(repo),
        currentUserIdProvider.overrideWithValue('v'),
        salesApiProvider.overrideWithValue(_NoCashApi()),
        mutationQueueProvider.overrideWithValue(EmptyMutationQueue()),
        localSettingsStoreProvider.overrideWithValue(MemorySettingsStore()),
        pendingMutationsCountProvider.overrideWith((ref) => Stream.value(0)),
        activeProductsProvider.overrideWith((ref) => Stream.value(const [])),
        locationsProvider.overrideWith((ref) => Stream.value(const [])),
        taxRatesProvider.overrideWith((ref) => Stream.value(const [])),
        priceTiersProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    container.listen(catalogSyncProvider, (_, _) {});
    await tester.runAsync(() => container.read(catalogSyncProvider.future));
    expect(repo.pulls, 1, reason: 'synchro de connexion');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.mobile(dark: true),
          home: Scaffold(
            body: SalesScreen(
              user: authUser(
                id: 'v',
                roles: const ['VENDEUR'],
                permissions: const ['sale.create', 'cash.session.manage'],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(repo.pulls, 2, reason: 'relue à l’entrée en Vente');
    // Catalogue local vide : l'écran le dit au lieu de rester muet.
    expect(
      find.text('Le catalogue ne contient aucun produit actif.'),
      findsOneWidget,
    );
  });
}
