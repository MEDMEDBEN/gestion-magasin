import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/photos.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/data/local/local_settings_store.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_repository.dart';
import 'package:gestion_magasin/features/catalog/presentation/catalog_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/widgets/form_panel.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';
import 'support/fakes.dart';

/// Mise à jour du catalogue neutralisée : les écrans lisent des valeurs fixes.
class _IdleSync extends CatalogSyncController {
  @override
  Future<void> build() async {}
}

/// Écritures branchées sur le faux client, sans base locale (les flux Drift ne
/// se résolvent pas dans le temps simulé de `testWidgets`).
class _ApiOnlyActions extends CatalogActions {
  _ApiOnlyActions(this.api, CatalogRepository unused) : super(api, unused);

  final RecordingCatalogApi api;

  Uint8List? lastPhoto;
  Map<String, int> lastPrices = const {};

  @override
  Future<Product> saveProduct(
    String? id,
    Map<String, Object?> fields, {
    Uint8List? photo,
    bool removePhoto = false,
    Map<String, int> prices = const {},
  }) {
    lastPhoto = photo;
    lastPrices = prices;
    return id == null
        ? api.createProduct(fields)
        : api.updateProduct(id, fields);
  }
}

const _allProductPermissions = [
  'price.manage',
  'product.read',
  'product.write',
  'product.disable',
  'location.manage',
];

AuthUser _admin() =>
    authUser(roles: const ['ADMIN'], permissions: _allProductPermissions);
AuthUser _vendeur() => authUser(
  id: 'v',
  roles: const ['VENDEUR'],
  permissions: const ['product.read', 'price.read'],
);
AuthUser _magasinier() => authUser(
  id: 'm',
  roles: const ['MAGASINIER'],
  permissions: const ['product.read', 'location.manage'],
);

void main() {
  late AppDatabase db;
  late RecordingCatalogApi api;
  late _ApiOnlyActions actions;

  setUp(() {
    db = AppDatabase.forTesting();
    api = RecordingCatalogApi();
  });
  tearDown(() => db.close());

  Widget wrap(
    AuthUser user, {
    List<Product> products = const [],
    List<ProductCategory> categories = const [],
    bool desktop = false,
    Uint8List? pickedPhoto,
  }) {
    final repo = CatalogRepository(db, LocalSettingsStore(db), api);
    actions = _ApiOnlyActions(api, repo);
    return ProviderScope(
      overrides: [
        catalogSyncProvider.overrideWith(_IdleSync.new),
        productsProvider.overrideWith((ref) => Stream.value(products)),
        categoriesProvider.overrideWith((ref) => Stream.value(categories)),
        locationsProvider.overrideWith(
          (ref) => Stream.value([
            for (final (id, type) in [('mag', 'MAGASIN'), ('dep', 'DEPOT')])
              StorageLocation(
                id: id,
                code: type,
                name: type,
                type: type,
                isActive: true,
                updatedAt: DateTime.utc(2026, 9, 14),
              ),
          ]),
        ),
        taxRatesProvider.overrideWith((ref) => Stream.value(const [])),
        priceTiersProvider.overrideWith(
          (ref) async => const [
            PriceTier(
              id: 'detail',
              code: 'DETAIL',
              name: 'Détail',
              isDefault: true,
            ),
            PriceTier(id: 'gros', code: 'GROS', name: 'Gros', isDefault: false),
          ],
        ),
        catalogActionsProvider.overrideWithValue(actions),
        pickPhotoProvider.overrideWithValue(() async => pickedPhoto),
      ],
      child: MaterialApp(
        theme: desktop
            ? AppTheme.desktop(dark: true)
            : AppTheme.mobile(dark: true),
        home: Scaffold(body: CatalogScreen(user: user)),
      ),
    );
  }

  testWidgets(
    'le VENDEUR consulte : ni création, ni catégories, ni emplacements',
    (tester) async {
      useScreenSize(tester, const Size(400, 800));
      await tester.pumpWidget(
        wrap(
          _vendeur(),
          products: [product(name: 'Câble 3G2.5', categoryId: 'cat')],
          categories: [category()],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Câble 3G2.5'), findsOneWidget);
      expect(find.text('Câbles'), findsWidgets);
      expect(find.text('Nouveau'), findsNothing);
      expect(find.text('Catégories'), findsNothing);
      expect(find.text('Emplacements'), findsNothing);

      // La fiche s'ouvre en lecture seule : aucune action d'enregistrement.
      await tester.tap(find.text('Câble 3G2.5'));
      await tester.pumpAndSettle();
      expect(find.text('Fiche produit'), findsOneWidget);
      expect(find.text('Enregistrer'), findsNothing);
    },
  );

  testWidgets(
    'filtre catégorie : on choisit une catégorie, puis « Toutes » le retire',
    (tester) async {
      useScreenSize(tester, const Size(400, 800));
      await tester.pumpWidget(
        wrap(_vendeur(), products: [product()], categories: [category()]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filtrer par catégorie'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Câbles').last);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(Chip, 'Câbles'), findsOneWidget);

      await tester.tap(find.byTooltip('Filtrer par catégorie'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Toutes les catégories').last);
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(Chip, 'Toutes les catégories'),
        findsOneWidget,
      );
    },
  );

  testWidgets('le MAGASINIER gère les emplacements, pas les catégories', (
    tester,
  ) async {
    useScreenSize(tester, const Size(400, 800));
    await tester.pumpWidget(wrap(_magasinier()));
    await tester.pumpAndSettle();

    expect(find.text('Emplacements'), findsOneWidget);
    expect(find.text('Catégories'), findsNothing);
    expect(find.text('Nouveau'), findsNothing);
  });

  testWidgets(
    'ADMIN : créer un produit n’envoie que les champs saisis (code-barres généré serveur)',
    (tester) async {
      useScreenSize(tester, const Size(400, 2200));
      await tester.pumpWidget(wrap(_admin()));
      await tester.pumpAndSettle();

      expect(find.text('Aucun produit'), findsOneWidget);
      await tester.tap(find.text('Nouveau'));
      await tester.pumpAndSettle();

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Disjoncteur 16A');
      await tester.enterText(fields.at(1), 'DIS-16A');
      // Champs : désignation, référence, code-barres, marque, stock magasin,
      // stock dépôt, seuil minimum…
      await tester.enterText(fields.at(4), '120');
      await tester.enterText(fields.at(6), '12,5');
      await tester.ensureVisible(find.text('Créer le produit'));
      await tester.tap(find.text('Créer le produit'));
      await tester.pumpAndSettle();

      final (id, sent) = api.productCalls.single;
      expect(id, isNull);
      expect(sent['name'], 'Disjoncteur 16A');
      expect(sent['sku'], 'DIS-16A');
      expect(sent['unit'], 'PIECE');
      // Quantité en chaîne décimale, jamais un double (règle 10).
      expect(sent['minThreshold'], '12.500');
      expect(sent.containsKey('barcode'), isFalse);
      // Stock à la saisie : seul le lieu renseigné part, en chaîne décimale.
      expect(sent['initialStock'], [
        {'locationId': 'mag', 'quantity': '120.000'},
      ]);
      expect(sent.containsKey('isActive'), isFalse);
    },
  );

  testWidgets('ADMIN : un seuil invalide est refusé AVANT l’envoi', (
    tester,
  ) async {
    useScreenSize(tester, const Size(400, 2200));
    await tester.pumpWidget(wrap(_admin()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nouveau'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Disjoncteur');
    await tester.enterText(fields.at(1), 'DIS');
    await tester.enterText(fields.at(6), '-3');
    await tester.ensureVisible(find.text('Créer le produit'));
    await tester.tap(find.text('Créer le produit'));
    await tester.pumpAndSettle();

    expect(find.text('Nombre positif, ex. 12,5'), findsOneWidget);
    expect(api.productCalls, isEmpty);
  });

  testWidgets('ADMIN desktop : modifier n’envoie QUE le champ changé', (
    tester,
  ) async {
    useScreenSize(tester, const Size(1400, 900));
    await tester.pumpWidget(
      wrap(
        _admin(),
        products: [product(id: 'p1', name: 'Ancien nom')],
        desktop: true,
      ),
    );
    await tester.pumpAndSettle();

    // Tableau dense sur desktop.
    expect(find.text('RÉFÉRENCE'), findsOneWidget);
    await tester.tap(find.text('Ancien nom'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'Nouveau nom');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    expect(api.productCalls.single.$1, 'p1');
    expect(api.productCalls.single.$2, {'name': 'Nouveau nom'});
  });

  test('photo : compressée en JPEG ≤ 1024 px ; fichier illisible refusé', () {
    final big = img.Image(width: 3000, height: 1500);
    final jpeg = compressPhoto(Uint8List.fromList(img.encodePng(big)))!;
    expect(jpeg.sublist(0, 3), [0xff, 0xd8, 0xff]);
    final decoded = img.decodeJpg(jpeg)!;
    expect((decoded.width, decoded.height), (1024, 512));
    expect(compressPhoto(Uint8List.fromList([1, 2, 3])), isNull);
  });

  testWidgets('ADMIN : la photo choisie part avec l’enregistrement', (
    tester,
  ) async {
    useScreenSize(tester, const Size(400, 2200));
    final photo = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 8, height: 8)),
    );
    await tester.pumpWidget(wrap(_admin(), pickedPhoto: photo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nouveau'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ajouter une photo'));
    await tester.pumpAndSettle();
    expect(find.text('Changer la photo'), findsOneWidget);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Disjoncteur');
    await tester.enterText(fields.at(1), 'DIS-PHOTO');
    await tester.ensureVisible(find.text('Créer le produit'));
    await tester.tap(find.text('Créer le produit'));
    await tester.pumpAndSettle();

    expect(actions.lastPhoto, photo);
  });

  testWidgets('prix : l’ADMIN n’envoie que le prix modifié, en centimes', (
    tester,
  ) async {
    useScreenSize(tester, const Size(1400, 1400));
    await tester.pumpWidget(
      wrap(
        _admin(),
        desktop: true,
        products: [
          product(id: 'p1', name: 'Disjoncteur').copyWith(
            prices: const [
              ProductPriceLine(priceTierId: 'detail', priceHt: 145000),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disjoncteur'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('PRIX GROS (HT)'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(FormPanelFrame),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    // Les prix ferment le formulaire : « Gros » est le dernier champ.
    await tester.enterText(find.byType(TextFormField).last, '1200,50');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    expect(actions.lastPrices, {'gros': 120050});
  });

  testWidgets('prix : le VENDEUR les voit sans pouvoir les modifier', (
    tester,
  ) async {
    useScreenSize(tester, const Size(400, 1600));
    await tester.pumpWidget(
      wrap(
        _vendeur(),
        products: [
          product(id: 'p1', name: 'Disjoncteur').copyWith(
            prices: const [
              ProductPriceLine(priceTierId: 'detail', priceHt: 145000),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disjoncteur'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Gros : non fixé'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(FormPanelFrame),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.textContaining('Détail : 1'), findsOneWidget);
    expect(find.text('Gros : non fixé'), findsOneWidget);
    expect(find.text('PRIX DÉTAIL (HT)'), findsNothing);
  });

  test('menu : le catalogue est proposé à tout compte qui a product.read', () {
    for (final user in [_admin(), _vendeur(), _magasinier()]) {
      expect(destinationsFor(user).map((d) => d.label), contains('Catalogue'));
    }
    expect(
      destinationsFor(authUser(permissions: const [])).map((d) => d.label),
      isNot(contains('Catalogue')),
    );
    final admin = authUser(
      permissions: const [..._allProductPermissions, 'user.manage'],
    );
    // Accueil, Catalogue, Rapports, Utilisateurs, Signalements, Messages,
    // Notifications, Mon profil : 8 entrées au POSTE (le scanner est mobile, il
    // lui faut une caméra), 9 sur mobile — les suivantes passent dans « Plus »
    // (AMPÈRE §7). « Rapports » suit `product.read` (P1 n°20) ; « Réappro »
    // n'est pas là, ce compte n'a pas `purchase.create`.
    final entries = destinationsFor(admin);
    expect(entries.where((d) => !d.mobileOnly), hasLength(8));
    expect(entries, hasLength(9));
    expect(entries.map((d) => d.label), contains('Rapports'));
    expect(entries.map((d) => d.label), isNot(contains('Réappro')));
  });

  test('changedFields ne garde que ce qui a bougé, `null` compris', () {
    expect(
      changedFields(
        {'name': 'A', 'brand': 'Legrand', 'unit': 'PIECE'},
        {'name': 'A', 'brand': null, 'unit': 'METRE'},
      ),
      {'brand': null, 'unit': 'METRE'},
    );
  });
}
