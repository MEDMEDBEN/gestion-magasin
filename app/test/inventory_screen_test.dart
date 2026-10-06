import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/inventory/data/inventory_api.dart';
import 'package:gestion_magasin/features/inventory/data/inventory_models.dart';
import 'package:gestion_magasin/features/inventory/presentation/inventory_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/widgets/ampere_controls.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';
import 'support/fakes.dart';

InventoryLine _line({
  String productId = 'p1',
  String theoretical = '50',
  String? counted,
  String difference = '0',
  InventoryLineState state = InventoryLineState.matching,
}) => InventoryLine(
  id: 'l-$productId',
  productId: productId,
  theoreticalQuantity: Decimal.parse(theoretical),
  countedQuantity: counted == null ? null : Decimal.parse(counted),
  difference: Decimal.parse(difference),
  state: state,
);

Inventory _inventory({
  InventoryStatus status = InventoryStatus.inProgress,
  DateTime? validatedAt,
  List<InventoryLine>? lines,
  InventoryType type = InventoryType.cycle,
}) => Inventory(
  id: 'i1',
  number: 'INV-2026-00003',
  status: status,
  type: type,
  locationId: 'depot',
  zone: 'Zone A',
  createdById: 'm',
  validatedAt: validatedAt,
  startedAt: DateTime.utc(2026, 9, 21),
  completedAt: status == InventoryStatus.completed
      ? DateTime.utc(2026, 9, 21, 1)
      : null,
  updatedAt: DateTime.utc(2026, 9, 21),
  lines: lines ?? [_line()],
);

StorageLocation _location(String id, String type, String name) =>
    StorageLocation(
      id: id,
      code: type,
      name: name,
      type: type,
      isActive: true,
      updatedAt: DateTime.utc(2026, 9, 14),
    );

/// Serveur en panne : éprouve l'état d'erreur de l'écran.
class _BrokenInventoryApi extends InventoryApi {
  _BrokenInventoryApi() : super(Dio());

  @override
  Future<InventoryPage> list({String? status, int limit = 100}) => Future.error(
    const ApiException(
      statusCode: 503,
      message: 'Serveur injoignable. Réessayez.',
    ),
  );
}

class _FakeInventoryApi extends InventoryApi {
  _FakeInventoryApi(this.inventories) : super(Dio());

  final List<Inventory> inventories;
  Map<String, Object?>? created;
  Map<String, Object?>? countedFields;
  String? validatedId;
  String? removedId;

  @override
  Future<void> remove(String id) async => removedId = id;

  @override
  Future<InventoryPage> list({String? status, int limit = 100}) async =>
      InventoryPage(
        data: inventories,
        meta: PageMeta(page: 1, limit: limit, total: inventories.length),
      );

  @override
  Future<Inventory> create(Map<String, Object?> fields) async {
    created = fields;
    return _inventory();
  }

  @override
  Future<Inventory> count(String id, Map<String, Object?> fields) async {
    countedFields = fields;
    return _inventory(
      status: InventoryStatus.completed,
      lines: [
        _line(
          counted: '47.5',
          difference: '-2.5',
          state: InventoryLineState.gap,
        ),
      ],
    );
  }

  @override
  Future<Inventory> validate(String id) async {
    validatedId = id;
    return _inventory(
      status: InventoryStatus.completed,
      validatedAt: DateTime.utc(2026, 9, 21, 2),
    );
  }
}

AuthUser _admin() => authUser(
  id: 'a',
  roles: const ['ADMIN'],
  permissions: const ['inventory.create', 'inventory.validate', 'product.read'],
);

AuthUser _magasinier() => authUser(
  id: 'm',
  roles: const ['MAGASINIER'],
  permissions: const ['inventory.create', 'product.read'],
);

Future<_FakeInventoryApi> _pump(
  WidgetTester tester,
  AuthUser user, {
  List<Inventory> inventories = const [],
}) async {
  useScreenSize(tester, const Size(500, 1400));
  final api = _FakeInventoryApi(inventories);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inventoryApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue('u'),
        documentCacheProvider.overrideWithValue(MemoryDocumentCache()),
        activeProductsProvider.overrideWith(
          (ref) => Stream.value([
            product(id: 'p1', name: 'Câble 3G2,5', sku: 'CAB-3G25'),
          ]),
        ),
        locationsProvider.overrideWith(
          (ref) => Stream.value([
            _location('magasin', 'MAGASIN', 'Magasin'),
            _location('depot', 'DEPOT', 'Dépôt'),
          ]),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: InventoryScreen(user: user)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  /// Retour terrain du 2026-10-06 : « créer puis saisir » faisait trop
  /// d'étapes. Lancer ouvre AUSSITÔT la saisie.
  testWidgets(
    'nouvel inventaire : lieu déjà choisi, la saisie s’ouvre aussitôt',
    (tester) async {
      final api = await _pump(tester, _magasinier());
      await tester.tap(find.text('Nouvel inventaire'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Commencer le comptage'));
      await tester.pumpAndSettle();

      expect(api.created, containsPair('type', 'COMPLET'));
      expect(api.created, containsPair('locationId', 'magasin'));
      // Directement dans la saisie, sans repasser par la liste.
      expect(find.text('Comptage INV-2026-00003'), findsOneWidget);
      expect(find.text('0 sur 1 produit(s) comptés'), findsOneWidget);
    },
  );

  testWidgets('quelques produits : zone et produits cochés partent', (
    tester,
  ) async {
    final api = await _pump(tester, _magasinier());
    await tester.tap(find.text('Nouvel inventaire'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dépôt').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quelques produits'));
    await tester.pumpAndSettle();

    // Sans produit coché : refusé avant le serveur.
    await tester.tap(find.text('Commencer le comptage'));
    await tester.pumpAndSettle();
    expect(find.textContaining('au moins un produit'), findsOneWidget);
    expect(api.created, isNull);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Zone A, rayon câbles…'),
      'Zone A',
    );
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Commencer le comptage'));
    await tester.pumpAndSettle();
    expect(api.created, containsPair('type', 'TOURNANT'));
    expect(api.created, containsPair('locationId', 'depot'));
    expect(api.created, containsPair('zone', 'Zone A'));
    expect(api.created!['productIds'], ['p1']);
    expect(api.created!['clientMutationId'], isA<String>());
  });

  testWidgets('en cours : un toucher ouvre la saisie ; le magasinier termine', (
    tester,
  ) async {
    final api = await _pump(tester, _magasinier(), inventories: [_inventory()]);
    expect(find.textContaining('0 sur 1 produit(s) comptés'), findsOneWidget);

    await tester.tap(find.text('INV-2026-00003'));
    await tester.pumpAndSettle();
    // Le théorique n'est PAS révélé avant le premier comptage.
    expect(find.textContaining('théorique 50'), findsNothing);
    // Le magasinier n'ajuste pas le stock.
    expect(find.text('Terminer et ajuster'), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Compté'),
      '47,5',
    );
    await tester.pumpAndSettle();
    expect(find.text('1 sur 1 produit(s) comptés'), findsOneWidget);
    await tester.tap(find.text('Terminer'));
    await tester.pumpAndSettle();

    expect(api.countedFields, containsPair('done', true));
    expect(api.countedFields!['lines'], [
      {'productId': 'p1', 'countedQuantity': '47.500'},
    ]);
    expect(api.validatedId, isNull);
    expect(find.textContaining('l’administrateur ajustera'), findsOneWidget);
  });

  testWidgets('incomplet : « Terminer » refusé, « Enregistrer » passe', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _magasinier(),
      inventories: [
        _inventory(
          lines: [
            _line(productId: 'p1'),
            _line(productId: 'p2'),
          ],
        ),
      ],
    );
    await tester.tap(find.text('INV-2026-00003'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Compté').first,
      '10',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terminer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 produit(s) sans quantité'), findsOneWidget);
    expect(api.countedFields, isNull);

    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(api.countedFields, containsPair('done', false));
  });

  testWidgets('admin : « Terminer et ajuster » en un seul passage', (
    tester,
  ) async {
    final api = await _pump(tester, _admin(), inventories: [_inventory()]);
    await tester.tap(find.text('INV-2026-00003'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Compté'),
      '47,5',
    );
    await tester.tap(find.text('Terminer et ajuster'));
    await tester.pumpAndSettle();

    expect(api.countedFields, containsPair('done', true));
    expect(api.validatedId, isNull); // rien sans confirmation
    expect(find.textContaining('1 produit(s) en écart'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Ajuster le stock'));
    await tester.pumpAndSettle();
    expect(api.validatedId, 'i1');
  });

  testWidgets(
    'terminé : fiche avec écarts formatés ; le magasinier n’y touche plus',
    (tester) async {
      final api = await _pump(
        tester,
        _magasinier(),
        inventories: [
          _inventory(
            status: InventoryStatus.completed,
            lines: [
              _line(
                counted: '47.5',
                difference: '-2.5',
                state: InventoryLineState.gap,
              ),
            ],
          ),
        ],
      );
      expect(find.text('À valider'), findsOneWidget);
      expect(
        find.textContaining('1 écart(s) sur 1 produit(s)'),
        findsOneWidget,
      );

      await tester.tap(find.text('INV-2026-00003'));
      await tester.pumpAndSettle();
      expect(find.text('Câble 3G2,5'), findsOneWidget);
      expect(find.text('Théorique 50 · compté 47,5'), findsOneWidget);
      expect(find.text('-2,5'), findsOneWidget);
      // Comptage terminé : le magasinier ne l'ajuste, ne le modifie ni ne le
      // supprime (le serveur refuse : 403).
      expect(find.text('Ajuster le stock'), findsNothing);
      expect(find.text('Modifier'), findsNothing);
      expect(find.text('Supprimer'), findsNothing);
      expect(api.countedFields, isNull);
    },
  );

  testWidgets(
    'admin : modifie un comptage terminé, repris avec son théorique',
    (tester) async {
      final api = await _pump(
        tester,
        _admin(),
        inventories: [
          _inventory(
            status: InventoryStatus.completed,
            lines: [
              _line(
                counted: '47.5',
                difference: '-2.5',
                state: InventoryLineState.gap,
              ),
            ],
          ),
        ],
      );
      await tester.tap(find.text('INV-2026-00003'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Modifier'));
      await tester.pumpAndSettle();
      expect(find.text('47,5'), findsOneWidget);
      expect(find.textContaining('théorique 50'), findsOneWidget);
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(api.countedFields, containsPair('done', false));
    },
  );

  testWidgets('admin : ajuster depuis la fiche, après confirmation', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _admin(),
      inventories: [
        _inventory(
          status: InventoryStatus.completed,
          lines: [
            _line(
              counted: '47.5',
              difference: '-2.5',
              state: InventoryLineState.gap,
            ),
          ],
        ),
      ],
    );
    await tester.tap(find.text('INV-2026-00003'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ajuster le stock'));
    await tester.pumpAndSettle();
    expect(api.validatedId, isNull);
    expect(find.textContaining('1 produit(s) en écart'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Ajuster le stock'));
    await tester.pumpAndSettle();
    expect(api.validatedId, 'i1');
  });

  testWidgets('admin : supprimer un comptage terminé, après confirmation', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _admin(),
      inventories: [
        _inventory(
          status: InventoryStatus.completed,
          lines: [
            _line(
              counted: '47.5',
              difference: '-2.5',
              state: InventoryLineState.gap,
            ),
          ],
        ),
      ],
    );
    await tester.tap(find.text('INV-2026-00003'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AmpereDangerButton, 'Supprimer'));
    await tester.pumpAndSettle();
    expect(api.removedId, isNull);
    expect(find.text('Supprimer INV-2026-00003 ?'), findsOneWidget);
    await tester.tap(find.widgetWithText(AmpereDangerButton, 'Supprimer').last);
    await tester.pumpAndSettle();
    expect(api.removedId, 'i1');
  });

  testWidgets('en cours : le magasinier le supprime depuis la saisie', (
    tester,
  ) async {
    final api = await _pump(tester, _magasinier(), inventories: [_inventory()]);
    await tester.tap(find.text('INV-2026-00003'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(AmpereDangerButton, 'Supprimer l’inventaire'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AmpereDangerButton, 'Supprimer'));
    await tester.pumpAndSettle();
    expect(api.removedId, 'i1');
  });

  testWidgets('ajusté : figé, ni modifier ni supprimer ni ajuster', (
    tester,
  ) async {
    await _pump(
      tester,
      _admin(),
      inventories: [
        _inventory(
          status: InventoryStatus.completed,
          validatedAt: DateTime.utc(2026, 9, 21, 2),
        ),
      ],
    );
    expect(find.text('Ajusté'), findsWidgets);
    await tester.tap(find.text('INV-2026-00003'));
    await tester.pumpAndSettle();
    expect(find.textContaining('figé'), findsOneWidget);
    expect(find.text('Modifier'), findsNothing);
    expect(find.text('Supprimer'), findsNothing);
    expect(find.text('Ajuster le stock'), findsNothing);
  });

  testWidgets('aucun inventaire : l’écran le dit au lieu de rester vide', (
    tester,
  ) async {
    await _pump(tester, _magasinier());
    expect(find.text('Aucun inventaire'), findsOneWidget);
    expect(find.textContaining('faites valider les écarts'), findsOneWidget);
  });

  testWidgets(
    'serveur injoignable : l’écran affiche l’erreur et propose de réessayer',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inventoryApiProvider.overrideWithValue(_BrokenInventoryApi()),
            currentUserIdProvider.overrideWithValue('u'),
            documentCacheProvider.overrideWithValue(MemoryDocumentCache()),
            activeProductsProvider.overrideWith(
              (ref) => Stream.value([product(id: 'p1')]),
            ),
            locationsProvider.overrideWith((ref) => Stream.value(const [])),
          ],
          child: MaterialApp(
            theme: AppTheme.mobile(dark: true),
            home: Scaffold(body: InventoryScreen(user: _magasinier())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Serveur injoignable'), findsOneWidget);
    },
  );

  testWidgets('comptage sans aucun écart : l’écran l’annonce clairement', (
    tester,
  ) async {
    await _pump(
      tester,
      _admin(),
      inventories: [
        _inventory(
          status: InventoryStatus.completed,
          lines: [_line(counted: '50', difference: '0')],
        ),
      ],
    );
    expect(find.textContaining('aucun écart'), findsOneWidget);
  });

  test('menu : « Inventaire » pour ADMIN et MAGASINIER, jamais le vendeur', () {
    for (final user in [_admin(), _magasinier()]) {
      expect(destinationsFor(user).map((d) => d.label), contains('Inventaire'));
    }
    expect(
      destinationsFor(
        authUser(
          roles: const ['VENDEUR'],
          permissions: const ['inventory.create'],
        ),
      ).map((d) => d.label),
      isNot(contains('Inventaire')),
    );
  });
}
