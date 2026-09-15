import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/features/auth/application/auth_controller.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/auth/presentation/change_password_screen.dart';
import 'package:gestion_magasin/features/auth/presentation/login_screen.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/stock/application/stock_controller.dart';
import 'package:gestion_magasin/features/stock/data/stock_api.dart';
import 'package:gestion_magasin/features/stock/data/stock_models.dart';
import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/sales/data/sales_api.dart';
import 'package:gestion_magasin/features/sales/data/sales_models.dart';
import 'package:gestion_magasin/features/users/data/users_api.dart';
import 'package:gestion_magasin/ui/adaptive_shell.dart';
import 'package:gestion_magasin/ui/breakpoints.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import '../support/catalog_fakes.dart';
import '../support/fakes.dart';

/// OUTIL (opt-in) de vérification visuelle : rend les vrais écrans avec les
/// vraies polices (Archivo, Lucide) et des données fictives, en PNG, pour
/// relire le design AMPÈRE sur toutes les tailles sans appareil sous la main.
///
///   flutter test test/tools/screen_captures_test.dart --dart-define=CAPTURE_OUT=/chemin/dossier
///
/// Sans `CAPTURE_OUT`, ces tests sont IGNORÉS : `flutter test` ne produit rien.
const out = String.fromEnvironment('CAPTURE_OUT');

class _SignedIn extends AuthController {
  _SignedIn(this.user);
  final AuthUser user;
  @override
  Future<AuthState> build() async => AuthSignedIn(user);
}

class _SignedOut extends AuthController {
  @override
  Future<AuthState> build() async => const AuthSignedOut();
}

final _users = [
  managedUser(
    id: 'me',
    fullName: 'Radhi Badache',
    email: 'admin@magasin.dz',
    roles: const ['ADMIN'],
    lastLoginAt: DateTime(2026, 9, 11, 9, 2),
  ),
  managedUser(
    id: 'u2',
    fullName: 'Amine Benali',
    email: 'amine@magasin.dz',
    roles: const ['VENDEUR'],
    lastLoginAt: DateTime(2026, 9, 10, 17, 45),
  ),
  managedUser(
    id: 'u3',
    fullName: 'Karim Saidi',
    email: null,
    phone: '+213555123456',
    roles: const ['MAGASINIER', 'VENDEUR'],
    lastLoginAt: DateTime(2026, 9, 11, 7, 58),
  ),
  managedUser(
    id: 'u4',
    fullName: 'Nadia Kaci',
    email: 'nadia@magasin.dz',
    roles: const ['VENDEUR'],
    mustChangePassword: true,
  ),
  managedUser(
    id: 'u5',
    fullName: 'Yacine Ouali',
    email: 'yacine@magasin.dz',
    roles: const ['MAGASINIER'],
    isActive: false,
    lastLoginAt: DateTime(2026, 8, 28, 16, 10),
  ),
];

class _IdleSync extends CatalogSyncController {
  @override
  Future<void> build() async {}
}

const _adminPermissions = [
  'user.manage',
  'product.read',
  'product.write',
  'product.disable',
  'location.manage',
  'stock.read.store',
  'stock.read.warehouse',
  'stock.loss',
  'stock.adjust.validate',
];

final _categories = [
  category(id: 'cab', name: 'Câbles'),
  category(id: 'cab-s', name: 'Câbles souples', parentId: 'cab'),
  category(id: 'prot', name: 'Protection'),
  category(id: 'ecl', name: 'Éclairage'),
];

final _products = [
  product(
    id: 'p1',
    name: 'Câble souple H07RN-F 3G2,5',
    sku: 'CAB-3G25',
    barcode: '3245060123458',
    brand: 'Nexans',
    categoryId: 'cab-s',
    unit: ProductUnit.metre,
    minThreshold: '100',
  ),
  product(
    id: 'p2',
    name: 'Disjoncteur DX³ 16A courbe C',
    sku: 'DIS-16C',
    barcode: '3245064074152',
    brand: 'Legrand',
    categoryId: 'prot',
    minThreshold: '10',
  ),
  product(
    id: 'p3',
    name: 'Interrupteur différentiel 40A 30mA',
    sku: 'ID-40-30',
    barcode: '2000000000015',
    brand: 'Schneider',
    categoryId: 'prot',
    minThreshold: '4',
  ),
  product(
    id: 'p4',
    name: 'Réglette LED 36W 120 cm',
    sku: 'LED-R36',
    barcode: '2000000000022',
    categoryId: 'ecl',
    minThreshold: '12.5',
  ),
  product(
    id: 'p5',
    name: 'Gaine ICTA Ø20 (couronne 100 m)',
    sku: 'GAI-20',
    barcode: '2000000000039',
    unit: ProductUnit.rouleau,
    minThreshold: '3',
  ),
];

StorageLocation _bin(String id, String code, String name) => StorageLocation(
  id: id,
  code: code,
  name: name,
  type: 'EMPLACEMENT',
  parentId: 'depot',
  isActive: true,
  updatedAt: DateTime.utc(2026, 9, 14),
);

final _locations = [
  StorageLocation(
    id: 'magasin',
    code: 'MAGASIN',
    name: 'Magasin',
    type: 'MAGASIN',
    isActive: true,
    updatedAt: DateTime.utc(2026, 9, 14),
  ),
  StorageLocation(
    id: 'depot',
    code: 'DEPOT',
    name: 'Dépôt',
    type: 'DEPOT',
    isActive: true,
    updatedAt: DateTime.utc(2026, 9, 14),
  ),
  _bin('l1', 'A-01-01-01', 'Zone A · Rayon 01 · Étagère 01 · Position 01'),
  _bin('l2', 'A-01-02-03', 'Zone A · Rayon 01 · Étagère 02 · Position 03'),
  _bin('l3', 'B-04-01-02', 'Zone B · Rayon 04 · Étagère 01 · Position 02'),
];

StockLevel _stock(String productId, String locationId, String quantity) =>
    StockLevel(
      productId: productId,
      locationId: locationId,
      quantity: Decimal.parse(quantity),
      reservedQuantity: Decimal.zero,
      inTransitQuantity: Decimal.zero,
      availableQuantity: Decimal.parse(quantity),
    );

final _stockByProduct = {
  'p1': ProductStock([
    _stock('p1', 'magasin', '120'),
    _stock('p1', 'depot', '480'),
  ]),
  'p2': ProductStock([
    _stock('p2', 'magasin', '4'),
    _stock('p2', 'depot', '2'),
  ]),
  'p3': ProductStock([
    _stock('p3', 'magasin', '6'),
    _stock('p3', 'depot', '12'),
  ]),
  'p4': ProductStock([
    _stock('p4', 'magasin', '9'),
    _stock('p4', 'depot', '40'),
  ]),
  'p5': ProductStock([_stock('p5', 'depot', '7')]),
};

class _CaptureStockApi extends StockApi {
  _CaptureStockApi() : super(Dio());

  @override
  Future<StockLossPage> losses({
    StockLossStatus? status,
    int limit = 200,
  }) async => StockLossPage(
    data: [
      StockLoss(
        id: 'l1',
        productId: 'p4',
        locationId: 'depot',
        quantity: Decimal.parse('2'),
        comment: 'Deux réglettes cassées au déchargement',
        status: StockLossStatus.pending,
        declaredById: 'm',
        createdAt: DateTime(2026, 9, 14, 8, 40),
      ),
      StockLoss(
        id: 'l2',
        productId: 'p1',
        locationId: 'magasin',
        quantity: Decimal.parse('3.5'),
        comment: 'Chute de coupe inutilisable',
        status: StockLossStatus.pending,
        declaredById: 'm',
        createdAt: DateTime(2026, 9, 14, 10, 5),
      ),
    ],
    meta: const PageMeta(page: 1, limit: 200, total: 2),
  );
}

class _CaptureSalesApi extends SalesApi {
  _CaptureSalesApi() : super(Dio());

  @override
  Future<CashSession?> currentCashSession() async => CashSession(
    id: 'cash',
    status: 'OUVERTE',
    openingFloat: 500000,
    cashSalesAmount: 1845000,
    cashSalesCount: 7,
    currentAmount: 2345000,
    openedAt: DateTime(2026, 9, 15, 8, 2),
  );

  @override
  Future<CustomerPage> customers({String? query, int limit = 50}) async =>
      const CustomerPage(
        data: [
          Customer(
            id: 'c1',
            name: 'SARL Électricité Benali',
            phone: '0550 12 34 56',
            priceTierId: 'gros',
            creditLimit: 5000000,
            balanceDue: 1284000,
            isActive: true,
          ),
          Customer(
            id: 'c2',
            name: 'Mourad Hamdi',
            phone: '0661 98 76 54',
            creditLimit: 0,
            balanceDue: 0,
            isActive: true,
          ),
          Customer(
            id: 'c3',
            name: 'Chantier Les Oliviers',
            creditLimit: 2000000,
            balanceDue: 1950000,
            isActive: true,
          ),
        ],
        meta: PageMeta(page: 1, limit: 50, total: 3),
      );
}

/// Vendeuse au comptoir : panier rempli à la douchette.
final _vendeuse = authUser(
  id: 'v',
  fullName: 'Nadia Kaci',
  roles: const ['VENDEUR'],
  permissions: const [
    'product.read',
    'stock.read.store',
    'sale.create',
    'sale.credit',
    'invoice.issue',
    'cash.session.manage',
    'customer.read',
    'customer.write',
    'customer.payment.create',
  ],
);

final _priced = [
  for (final (p, ht) in [
    (_products[0], 14500),
    (_products[1], 89000),
    (_products[2], 1250000),
    (_products[3], 185000),
    (_products[4], 420000),
  ])
    p.copyWith(
      taxRateId: 'tva19',
      prices: [ProductPriceLine(priceTierId: 'detail', priceHt: ht)],
    ),
];

Future<void> _fillCart(WidgetTester t) async {
  await t.tap(find.text('Vente'));
  await t.pumpAndSettle();
  for (final code in [
    '3245060123458',
    '3245064074152',
    '3245064074152',
    '2000000000022',
  ]) {
    await t.enterText(find.byType(TextField).first, code);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();
  }
}

Future<void> _loadFonts() async {
  final archivo = FontLoader('Archivo')
    ..addFont(rootBundle.load('fonts/Archivo-Variable.ttf'));
  final lucide = FontLoader('packages/lucide_icons_flutter/Lucide')
    ..addFont(
      rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
    );
  await Future.wait([archivo.load(), lucide.load()]);
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required Size size,
  required Widget home,
  bool dark = true,
  AuthController Function()? auth,
  AuthUser? user,
  int foreignPending = 0,
  Future<void> Function(WidgetTester)? interact,
  List<Product>? products,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = AppDatabase.forTesting();
  final key = GlobalKey();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(
          auth ??
              () => _SignedIn(
                user ??
                    authUser(
                      id: 'me',
                      fullName: 'Radhi Badache',
                      permissions: _adminPermissions,
                    ),
              ),
        ),
        catalogSyncProvider.overrideWith(_IdleSync.new),
        productsProvider.overrideWith(
          (ref) => Stream.value(products ?? _products),
        ),
        categoriesProvider.overrideWith((ref) => Stream.value(_categories)),
        locationsProvider.overrideWith((ref) => Stream.value(_locations)),
        taxRatesProvider.overrideWith(
          (ref) => Stream.value([
            TaxRate(
              id: 'tva19',
              code: 'TVA19',
              name: 'TVA 19 %',
              rate: '19.00',
              isDefault: true,
              isActive: true,
              updatedAt: DateTime.utc(2026),
            ),
          ]),
        ),
        activeProductsProvider.overrideWith(
          (ref) => Stream.value(products ?? _products),
        ),
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
        salesApiProvider.overrideWithValue(_CaptureSalesApi()),
        stockByProductProvider.overrideWith((ref) async => _stockByProduct),
        stockApiProvider.overrideWithValue(_CaptureStockApi()),
        appDatabaseProvider.overrideWithValue(db),
        usersApiProvider.overrideWithValue(FakeUsersApi(users: _users)),
        currentUserIdProvider.overrideWithValue('me'),
        pendingMutationsCountProvider.overrideWith((ref) => Stream.value(0)),
        foreignPendingMutationsCountProvider.overrideWith(
          (ref) => Stream.value(foreignPending),
        ),
        rejectedMutationsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          builder: (context, child) => Theme(
            data: isDesktopWidth(MediaQuery.sizeOf(context).width)
                ? AppTheme.desktop(dark: dark)
                : AppTheme.mobile(dark: dark),
            child: child!,
          ),
          home: home,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (interact != null) {
    await interact(tester);
    await tester.pumpAndSettle();
  }

  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(db.close);
}

/// Mobile : l'admin a plus de 4 destinations, les dernières sont sous « Plus ».
Future<void> _viaMore(WidgetTester t, String label) async {
  await t.tap(find.text('Plus'));
  await t.pumpAndSettle();
  await t.tap(find.text(label));
}

void main() {
  setUpAll(_loadFonts);
  const skip = out == '';

  testWidgets(
    '01 login desktop sombre',
    skip: skip,
    (t) => _capture(
      t,
      name: '01_login_desktop_sombre',
      size: const Size(1440, 900),
      home: const LoginScreen(),
      auth: _SignedOut.new,
    ),
  );
  testWidgets(
    '02 login mobile clair',
    skip: skip,
    (t) => _capture(
      t,
      name: '02_login_mobile_clair',
      size: const Size(390, 844),
      home: const LoginScreen(),
      auth: _SignedOut.new,
      dark: false,
    ),
  );
  testWidgets(
    '03 mot de passe force mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '03_mdp_force_mobile',
      size: const Size(390, 844),
      home: const ChangePasswordScreen(),
    ),
  );
  testWidgets(
    '04 utilisateurs desktop sombre',
    skip: skip,
    (t) => _capture(
      t,
      name: '04_utilisateurs_desktop_sombre',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Utilisateurs')),
    ),
  );
  testWidgets(
    '05 utilisateurs desktop clair',
    skip: skip,
    (t) => _capture(
      t,
      name: '05_utilisateurs_desktop_clair',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      dark: false,
      interact: (t) async => t.tap(find.text('Utilisateurs')),
    ),
  );
  testWidgets(
    '06 formulaire panneau desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '06_formulaire_panneau_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Utilisateurs'));
        await t.pumpAndSettle();
        await t.tap(find.text('Karim Saidi'));
      },
    ),
  );
  testWidgets(
    '07 tablette rail',
    skip: skip,
    (t) => _capture(
      t,
      name: '07_tablette_rail',
      size: const Size(1024, 768),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.byTooltip('Utilisateurs')),
    ),
  );
  testWidgets(
    '08 utilisateurs mobile sombre',
    skip: skip,
    (t) => _capture(
      t,
      name: '08_utilisateurs_mobile_sombre',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) => _viaMore(t, 'Utilisateurs'),
    ),
  );
  testWidgets(
    '09 formulaire plein ecran mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '09_formulaire_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await _viaMore(t, 'Utilisateurs');
        await t.pumpAndSettle();
        await t.tap(find.text('Nouveau'));
      },
    ),
  );
  testWidgets(
    '10 confirmation danger desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '10_confirmation_danger',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Utilisateurs'));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Actions').at(1));
        await t.pumpAndSettle();
        await t.tap(find.text('Désactiver'));
      },
    ),
  );
  testWidgets(
    '11 profil mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '11_profil_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      foreignPending: 2,
      interact: (t) => _viaMore(t, 'Mon profil'),
    ),
  );

  testWidgets(
    '12 catalogue desktop sombre',
    skip: skip,
    (t) => _capture(
      t,
      name: '12_catalogue_desktop_sombre',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Catalogue')),
    ),
  );
  testWidgets(
    '13 fiche produit panneau desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '13_produit_panneau_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Catalogue'));
        await t.pumpAndSettle();
        await t.tap(find.text('Disjoncteur DX³ 16A courbe C'));
      },
    ),
  );
  testWidgets(
    '14 catalogue mobile clair vendeur',
    skip: skip,
    (t) => _capture(
      t,
      name: '14_catalogue_mobile_clair_vendeur',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      dark: false,
      user: authUser(
        id: 'v',
        fullName: 'Amine Benali',
        roles: const ['VENDEUR'],
        permissions: const ['product.read', 'price.read'],
      ),
      interact: (t) async => t.tap(find.text('Catalogue')),
    ),
  );
  testWidgets(
    '15 categories desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '15_categories_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Catalogue'));
        await t.pumpAndSettle();
        await t.tap(find.text('Catégories'));
      },
    ),
  );
  testWidgets(
    '16 emplacements mobile magasinier',
    skip: skip,
    (t) => _capture(
      t,
      name: '16_emplacements_mobile_magasinier',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      user: authUser(
        id: 'm',
        fullName: 'Karim Saidi',
        roles: const ['MAGASINIER'],
        permissions: const ['product.read', 'location.manage'],
      ),
      interact: (t) async {
        await t.tap(find.text('Catalogue'));
        await t.pumpAndSettle();
        await t.tap(find.text('Emplacements'));
      },
    ),
  );
  testWidgets(
    '17 nouveau produit mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '17_nouveau_produit_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Catalogue'));
        await t.pumpAndSettle();
        await t.tap(find.text('Nouveau'));
      },
    ),
  );

  testWidgets(
    '18 stock desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '18_stock_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Stock')),
    ),
  );
  testWidgets(
    '19 pertes a valider admin mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '19_pertes_admin_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Stock'));
        await t.pumpAndSettle();
        await t.tap(find.text('Pertes'));
      },
    ),
  );
  testWidgets(
    '20 declarer perte magasinier mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '20_declarer_perte_magasinier',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      user: authUser(
        id: 'm',
        fullName: 'Karim Saidi',
        roles: const ['MAGASINIER'],
        permissions: const [
          'product.read',
          'location.manage',
          'stock.read.store',
          'stock.read.warehouse',
          'stock.loss',
        ],
      ),
      interact: (t) async {
        await t.tap(find.text('Stock'));
        await t.pumpAndSettle();
        await t.tap(find.text('Pertes'));
        await t.pumpAndSettle();
        await t.tap(find.text('Déclarer une perte'));
      },
    ),
  );

  testWidgets(
    '21 vente desktop vendeuse',
    skip: skip,
    (t) => _capture(
      t,
      name: '21_vente_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      user: _vendeuse,
      products: _priced,
      interact: _fillCart,
    ),
  );
  testWidgets(
    '22 vente mobile vendeuse',
    skip: skip,
    (t) => _capture(
      t,
      name: '22_vente_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      user: _vendeuse,
      products: _priced,
      interact: _fillCart,
    ),
  );
  testWidgets(
    '23 clients mobile vendeuse',
    skip: skip,
    (t) => _capture(
      t,
      name: '23_clients_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      user: _vendeuse,
      products: _priced,
      interact: (t) async {
        await t.tap(find.text('Vente'));
        await t.pumpAndSettle();
        await t.tap(find.text('Clients'));
      },
    ),
  );
}
