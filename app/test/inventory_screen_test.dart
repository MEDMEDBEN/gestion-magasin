import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/inventory/data/inventory_api.dart';
import 'package:gestion_magasin/features/inventory/data/inventory_models.dart';
import 'package:gestion_magasin/features/inventory/presentation/inventory_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
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
  testWidgets(
    'lancer un inventaire TOURNANT : type, zone et produits partent',
    (tester) async {
      final api = await _pump(tester, _magasinier());

      await tester.tap(find.text('Lancer un inventaire'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dépôt').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Tournant'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Zone A, rayon câbles…'),
        'Zone A',
      );
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Lancer le comptage'));
      await tester.pumpAndSettle();

      expect(api.created, containsPair('type', 'TOURNANT'));
      expect(api.created, containsPair('zone', 'Zone A'));
      expect(api.created!['productIds'], ['p1']);
      expect(api.created!['clientMutationId'], isA<String>());
    },
  );

  testWidgets('un tournant sans produit coché ne part pas', (tester) async {
    final api = await _pump(tester, _magasinier());
    await tester.tap(find.text('Lancer un inventaire'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dépôt').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tournant'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lancer le comptage'));
    await tester.pumpAndSettle();

    expect(find.textContaining('au moins un produit'), findsOneWidget);
    expect(api.created, isNull);
  });

  testWidgets('le comptage part au serveur, et n’annonce AUCUN ajustement', (
    tester,
  ) async {
    final api = await _pump(tester, _magasinier(), inventories: [_inventory()]);
    expect(find.textContaining('0 sur 1 produit(s) comptés'), findsOneWidget);

    await tester.tap(find.text('INV-2026-00003'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saisir le comptage'));
    await tester.pumpAndSettle();

    // Le théorique n'est PAS révélé avant le premier comptage.
    expect(find.textContaining('Théorique 50'), findsNothing);
    expect(find.textContaining('ne bouge qu’à la validation'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantité comptée'),
      '47,5',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terminer le comptage'));
    await tester.pumpAndSettle();

    expect(api.countedFields, containsPair('done', true));
    expect(api.countedFields!['lines'], [
      {'productId': 'p1', 'countedQuantity': '47.500'},
    ]);
  });

  testWidgets(
    'comptage incomplet : « Terminer » est refusé, « en cours » passe',
    (tester) async {
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
      await tester.tap(find.text('Saisir le comptage'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Quantité comptée').first,
        '10',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Terminer le comptage'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Comptage incomplet'), findsOneWidget);
      expect(api.countedFields, isNull);

      await tester.tap(find.text('Enregistrer en cours'));
      await tester.pumpAndSettle();
      expect(api.countedFields, containsPair('done', false));
    },
  );

  testWidgets('le magasinier ne valide JAMAIS les ajustements', (tester) async {
    await _pump(
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
    expect(find.textContaining('1 écart(s) sur 1 produit(s)'), findsOneWidget);

    await tester.tap(find.text('INV-2026-00003'));
    await tester.pumpAndSettle();
    expect(find.text('Valider les ajustements'), findsNothing);
    expect(find.text('Saisir le comptage'), findsNothing);
  });

  testWidgets('l’ADMIN valide, après une confirmation qui annonce l’effet', (
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
    await tester.tap(find.text('Valider les ajustements'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 ligne(s) en écart'), findsOneWidget);
    expect(find.textContaining('mouvement daté'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Valider'));
    await tester.pumpAndSettle();

    expect(api.validatedId, 'i1');
  });

  testWidgets('un inventaire déjà ajusté est clos : plus aucune action', (
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
    expect(find.text('Ajusté'), findsOneWidget);
    await tester.tap(find.text('INV-2026-00003'));
    await tester.pumpAndSettle();
    expect(find.text('Valider les ajustements'), findsNothing);
    expect(find.text('Saisir le comptage'), findsNothing);
    expect(find.text('Voir les écarts'), findsOneWidget);
  });

  testWidgets('« Voir les écarts » montre des quantités FORMATÉES', (
    tester,
  ) async {
    await _pump(
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
    await tester.tap(find.text('Voir les écarts'));
    await tester.pumpAndSettle();

    expect(find.text('Câble 3G2,5'), findsOneWidget);
    expect(find.text('Théorique 50 · compté 47,5'), findsOneWidget);
    expect(find.text('-2,5'), findsOneWidget);
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

  testWidgets('un comptage déjà entamé propose de le REPRENDRE', (
    tester,
  ) async {
    await _pump(
      tester,
      _magasinier(),
      inventories: [
        _inventory(
          lines: [_line(counted: '12', difference: '0')],
        ),
      ],
    );
    expect(find.textContaining('1 sur 1 produit(s) comptés'), findsOneWidget);
    await tester.tap(find.text('INV-2026-00003'));
    await tester.pumpAndSettle();
    expect(find.text('Reprendre le comptage'), findsOneWidget);
    expect(find.text('Saisir le comptage'), findsNothing);
  });

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
