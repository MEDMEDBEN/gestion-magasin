import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/money.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/core/quantity.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/replenishment/application/replenishment_controller.dart';
import 'package:gestion_magasin/features/replenishment/data/replenishment_api.dart';
import 'package:gestion_magasin/features/replenishment/data/replenishment_models.dart';
import 'package:gestion_magasin/features/replenishment/presentation/replenishment_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

/// Réapprovisionnement (P1 n°19) : l'écran propose, l'utilisateur ajuste, et
/// rien n'est commandé ici.
class _FakeReplenishmentApi extends ReplenishmentApi {
  _FakeReplenishmentApi(this.items) : super(Dio());

  List<ReplenishmentLine> items;
  final calls = <bool>[];

  @override
  Future<ReplenishmentPage> list({
    int page = 1,
    int limit = 50,
    bool outOfStockOnly = false,
    String? supplierId,
  }) async {
    calls.add(outOfStockOnly);
    final visible = [
      for (final line in items)
        if (!outOfStockOnly || line.isOutOfStock) line,
    ];
    return ReplenishmentPage(
      data: visible,
      meta: PageMeta(page: page, limit: limit, total: visible.length),
      outOfStockCount: items.where((l) => l.isOutOfStock).length,
    );
  }
}

ReplenishmentLine _line({
  String productId = 'p1',
  String name = 'Câble 2,5 mm²',
  String quantity = '8.000',
  String minThreshold = '20.000',
  String suggestedQuantity = '32.000',
  bool isOutOfStock = false,
  String? supplierName = 'Sonelec',
  int? lastPurchasePriceHt = 15000,
}) => ReplenishmentLine(
  productId: productId,
  sku: 'CAB-25',
  name: name,
  unit: 'METRE',
  quantity: quantity,
  minThreshold: minThreshold,
  suggestedQuantity: suggestedQuantity,
  isOutOfStock: isOutOfStock,
  supplierName: supplierName,
  lastPurchasePriceHt: lastPurchasePriceHt,
);

AuthUser _magasinier() => authUser(
  id: 'moi',
  fullName: 'Nadia Kaci',
  roles: const ['MAGASINIER'],
  permissions: const ['purchase.create', 'product.read'],
);

/// Capture le `ref` de l'écran pour pouvoir provoquer un VRAI rafraîchissement
/// (ce que fait le battement de synchro en usage réel).
WidgetRef? _capturedRef;

Future<_FakeReplenishmentApi> _pump(
  WidgetTester tester, {
  required List<ReplenishmentLine> items,
  AuthUser? user,
}) async {
  useScreenSize(tester, const Size(900, 1400));
  final api = _FakeReplenishmentApi(items);
  _capturedRef = null;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        replenishmentApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue(user?.id ?? 'moi'),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              _capturedRef = ref;
              return const ReplenishmentScreen();
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

/// Relit la liste comme le ferait le battement de synchro.
Future<void> _refresh(WidgetTester tester) async {
  _capturedRef!.invalidate(replenishmentProvider((outOfStockOnly: false)));
  await tester.pumpAndSettle();
}

/// Le champ « À commander » de la tuile qui porte ce nom de produit.
Finder _fieldOf(String productName) => find.descendant(
  of: find.ancestor(of: find.text(productName), matching: find.byType(Card)),
  matching: find.byType(TextField),
);

void main() {
  testWidgets('rien à racheter : l’écran explique le rôle du seuil', (
    tester,
  ) async {
    await _pump(tester, items: const []);

    expect(find.text('Rien à racheter'), findsOneWidget);
    // Sans cette phrase, un seuil à 0 passe pour une panne de l'écran.
    expect(find.textContaining('sans seuil'), findsOneWidget);
  });

  testWidgets('une ligne montre le reste, le seuil et le fournisseur', (
    tester,
  ) async {
    await _pump(tester, items: [_line()]);

    expect(find.text('Câble 2,5 mm²'), findsOneWidget);
    // L'unité est ABRÉGÉE par la table du catalogue (« m »), pas l'enum brut.
    expect(find.textContaining('reste 8 m'), findsOneWidget);
    expect(find.textContaining('seuil 20'), findsOneWidget);
    expect(find.textContaining('Sonelec'), findsOneWidget);
    expect(find.text('STOCK FAIBLE'), findsOneWidget);
  });

  testWidgets('une rupture se distingue d’un stock faible', (tester) async {
    await _pump(tester, items: [_line(quantity: '0.000', isOutOfStock: true)]);

    expect(find.text('RUPTURE'), findsOneWidget);
    expect(find.text('STOCK FAIBLE'), findsNothing);
  });

  testWidgets('la quantité proposée est pré-remplie et MODIFIABLE (spec §19)', (
    tester,
  ) async {
    await _pump(tester, items: [_line()]);

    // Pré-remplie avec la proposition du serveur, zéros de fin retirés.
    expect(find.widgetWithText(TextField, '32'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '50');
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, '50'), findsOneWidget);
  });

  /// Le montant suit la quantité SAISIE : un montant figé sur la proposition
  /// serait faux dès la première frappe.
  testWidgets('le coût estimé suit la quantité saisie', (tester) async {
    await _pump(tester, items: [_line()]);

    // L'attendu passe par `formatDA` : le séparateur de milliers est une espace
    // FINE INSÉCABLE, et une espace normale écrite ici donnerait un
    // faux-négatif — le piège que `core/money.dart` documente. Ce qui est
    // éprouvé, c'est la multiplication, pas la typographie.
    expect(find.textContaining(formatDA(32 * 15000)), findsOneWidget);

    await tester.enterText(find.byType(TextField), '10');
    await tester.pumpAndSettle();

    expect(find.textContaining(formatDA(10 * 15000)), findsOneWidget);
    expect(find.textContaining(formatDA(32 * 15000)), findsNothing);
  });

  testWidgets('sans prix d’achat connu, aucun montant n’est inventé', (
    tester,
  ) async {
    await _pump(tester, items: [_line(lastPurchasePriceHt: null)]);

    expect(find.textContaining('Prix d’achat inconnu'), findsOneWidget);
    expect(find.textContaining('DA'), findsNothing);
  });

  testWidgets('le filtre « ruptures seulement » repart chercher au serveur', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      items: [
        _line(),
        _line(
          productId: 'p2',
          name: 'Disjoncteur 16A',
          quantity: '0.000',
          isOutOfStock: true,
        ),
      ],
    );

    expect(api.calls, [false]);
    expect(find.text('Disjoncteur 16A'), findsOneWidget);
    expect(find.text('Câble 2,5 mm²'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Ruptures seulement'));
    await tester.pumpAndSettle();

    // Le filtre est appliqué par le SERVEUR, pas en masquant des lignes déjà
    // chargées : sinon le compteur et la pagination mentent.
    expect(api.calls, [false, true]);
    expect(find.text('Câble 2,5 mm²'), findsNothing);
    expect(find.text('Disjoncteur 16A'), findsOneWidget);
  });

  testWidgets('le compteur annonce le total et les ruptures', (tester) async {
    await _pump(
      tester,
      items: [
        _line(),
        _line(productId: 'p2', quantity: '0.000', isOutOfStock: true),
      ],
    );

    expect(find.textContaining('2 à racheter'), findsOneWidget);
    expect(find.textContaining('1 en rupture'), findsOneWidget);
  });

  /// Miroir du guard serveur (`purchase.create`, admin ou magasinier) : le
  /// vendeur ne peut pas commander et n'a pas accès aux fournisseurs.
  /// LE bug que la revue a trouvé : sans clé par produit, Flutter réassocie
  /// l'état des champs par POSITION. Après un rafraîchissement qui change
  /// l'ordre, la quantité saisie se retrouvait sur un AUTRE produit — une
  /// commande fausse, et invisible.
  testWidgets('un réordonnancement ne déplace PAS la quantité saisie', (
    tester,
  ) async {
    final cable = _line(productId: 'p1', name: 'Câble 2,5 mm²');
    final disjoncteur = _line(
      productId: 'p2',
      name: 'Disjoncteur 16A',
      suggestedQuantity: '12.000',
    );
    final api = await _pump(tester, items: [cable, disjoncteur]);

    await tester.enterText(_fieldOf('Câble 2,5 mm²'), '50');
    await tester.pumpAndSettle();

    // Le disjoncteur devient le plus urgent : l'ordre s'inverse.
    api.items = [disjoncteur, cable];
    await _refresh(tester);

    // La saisie doit avoir suivi SON produit, et l'autre garder sa proposition.
    expect(_fieldOf('Câble 2,5 mm²'), findsOneWidget);
    expect(
      tester.widget<TextField>(_fieldOf('Câble 2,5 mm²')).controller!.text,
      '50',
    );
    expect(
      tester.widget<TextField>(_fieldOf('Disjoncteur 16A')).controller!.text,
      '12',
    );
  });

  /// L'inverse est vrai aussi : une nouvelle proposition du serveur doit être
  /// reprise, mais jamais écraser une saisie.
  testWidgets('une nouvelle proposition est reprise, sauf si l’on a saisi', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      items: [
        _line(productId: 'p1', name: 'Câble 2,5 mm²'),
        _line(productId: 'p2', name: 'Disjoncteur 16A'),
      ],
    );

    await tester.enterText(_fieldOf('Disjoncteur 16A'), '7');
    await tester.pumpAndSettle();

    // Le serveur propose autre chose pour les deux produits.
    api.items = [
      _line(
        productId: 'p1',
        name: 'Câble 2,5 mm²',
        suggestedQuantity: '64.000',
      ),
      _line(
        productId: 'p2',
        name: 'Disjoncteur 16A',
        suggestedQuantity: '99.000',
      ),
    ];
    await _refresh(tester);

    // Non saisi : la nouvelle proposition prend la place.
    expect(
      tester.widget<TextField>(_fieldOf('Câble 2,5 mm²')).controller!.text,
      '64',
    );
    // Saisi : la frappe de l'utilisateur est intouchable.
    expect(
      tester.widget<TextField>(_fieldOf('Disjoncteur 16A')).controller!.text,
      '7',
    );
  });

  group('accès à l’écran', () {
    List<String> labelsFor(AuthUser user) =>
        destinationsFor(user).map((destination) => destination.label).toList();

    test('le magasinier et l’admin ont « Réappro », le vendeur non', () {
      expect(labelsFor(_magasinier()), contains('Réappro'));
      expect(
        labelsFor(
          authUser(
            id: 'chef',
            fullName: 'Radhi',
            roles: const ['ADMIN'],
            permissions: const ['purchase.create'],
          ),
        ),
        contains('Réappro'),
      );
      expect(
        labelsFor(
          authUser(
            id: 'v',
            fullName: 'Amine',
            roles: const ['VENDEUR'],
            permissions: const ['sale.create', 'product.read'],
          ),
        ),
        isNot(contains('Réappro')),
      );
    });

    /// Le rôle ne suffit pas : c'est la permission que le serveur exige.
    test('un magasinier sans `purchase.create` n’y a pas droit', () {
      expect(
        labelsFor(
          authUser(
            id: 'm2',
            fullName: 'Karim',
            roles: const ['MAGASINIER'],
            permissions: const ['product.read'],
          ),
        ),
        isNot(contains('Réappro')),
      );
    });
  });

  group('coût estimé', () {
    test('arrondi à l’entier, en centimes', () {
      expect(estimatedCost(Decimal.parse('32'), 15000), 480000);
      expect(estimatedCost(Decimal.parse('2.5'), 999), 2498);
      expect(estimatedCost(quantityFromJson('0.333'), 100), 33);
    });
  });
}
