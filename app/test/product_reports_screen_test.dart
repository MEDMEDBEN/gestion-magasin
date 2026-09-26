import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/money.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/product_reports/data/product_report_models.dart';
import 'package:gestion_magasin/features/product_reports/data/product_reports_api.dart';
import 'package:gestion_magasin/features/product_reports/presentation/product_reports_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

/// Rapports produits (P1 n°20) : deux questions opposées, « qu'est-ce qui ne part
/// pas » et « qu'est-ce qu'on me réclame ».
class _FakeApi extends ProductReportsApi {
  _FakeApi({this.dormantRows = const [], this.demandData}) : super(Dio());

  List<DormantProduct> dormantRows;
  ProductDemand? demandData;
  final dormantDays = <int>[];
  final demandDays = <int>[];

  @override
  Future<DormantProductPage> dormant({int days = 120, int limit = 50}) async {
    dormantDays.add(days);
    return DormantProductPage(
      data: dormantRows,
      meta: PageMeta(page: 1, limit: limit, total: dormantRows.length),
      days: days,
      totalSleepingValueHt: dormantRows.fold<int?>(
        null,
        (sum, row) => row.sleepingValueHt == null
            ? sum
            : (sum ?? 0) + row.sleepingValueHt!,
      ),
    );
  }

  @override
  Future<ProductDemand> demand({int days = 30}) async {
    demandDays.add(days);
    return (demandData ?? const ProductDemand()).copyWith(days: days);
  }
}

/// Rend UNE ligne en annonçant un total bien plus grand : le cas d'une liste
/// tronquée, que l'écran doit signaler.
class _TruncatedApi extends ProductReportsApi {
  _TruncatedApi(this._inner) : super(Dio());

  final _FakeApi _inner;

  @override
  Future<DormantProductPage> dormant({int days = 120}) async {
    final page = await _inner.dormant(days: days);
    return page.copyWith(meta: page.meta.copyWith(total: 137));
  }

  @override
  Future<ProductDemand> demand({int days = 30}) => _inner.demand(days: days);
}

DormantProduct _dormant({
  String productId = 'p1',
  String name = 'Câble 2,5 mm²',
  String quantity = '39.000',
  DateTime? lastSoldAt,
  int? sleepingValueHt = 97500,
}) => DormantProduct(
  productId: productId,
  sku: 'CAB-25',
  name: name,
  unit: 'METRE',
  quantity: quantity,
  lastSoldAt: lastSoldAt,
  lastMovementAt: lastSoldAt,
  sleepingValueHt: sleepingValueHt,
);

DemandLine _line({
  String productId = 'p1',
  String name = 'Câble 2,5 mm²',
  String quantity = '124.000',
  int? revenueHt,
}) => DemandLine(
  productId: productId,
  sku: 'CAB-25',
  name: name,
  unit: 'METRE',
  quantity: quantity,
  revenueHt: revenueHt,
);

Future<_FakeApi> _pump(
  WidgetTester tester, {
  List<DormantProduct> dormantRows = const [],
  ProductDemand? demand,
}) async {
  useScreenSize(tester, const Size(900, 1400));
  final api = _FakeApi(dormantRows: dormantRows, demandData: demand);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productReportsApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue('moi'),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: const Scaffold(body: ProductReportsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('rien ne dort : l’écran explique que c’est la VENTE qui compte', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Rien ne dort'), findsOneWidget);
    // Sans cette phrase, on croit que la réception remet le compteur à zéro.
    expect(find.textContaining('réception ne remet pas'), findsOneWidget);
  });

  testWidgets('un dormant montre son stock, sa dernière vente et sa valeur', (
    tester,
  ) async {
    await _pump(
      tester,
      dormantRows: [_dormant(lastSoldAt: DateTime.utc(2026, 3, 2))],
    );

    expect(find.text('Câble 2,5 mm²'), findsOneWidget);
    expect(find.textContaining('39 m en stock'), findsOneWidget);
    expect(find.textContaining('dernière vente'), findsOneWidget);
    expect(find.text(formatDA(97500)), findsOneWidget);
  });

  testWidgets(
    'jamais vendu : l’écran le DIT au lieu d’afficher une date vide',
    (tester) async {
      await _pump(tester, dormantRows: [_dormant()]);

      expect(find.textContaining('jamais vendu'), findsOneWidget);
    },
  );

  testWidgets('sans prix d’achat connu, aucune valeur n’est inventée', (
    tester,
  ) async {
    await _pump(tester, dormantRows: [_dormant(sleepingValueHt: null)]);

    expect(find.text('valeur inconnue'), findsOneWidget);
    expect(find.textContaining('DA'), findsNothing);
  });

  testWidgets('le total immobilisé est annoncé', (tester) async {
    await _pump(
      tester,
      dormantRows: [
        _dormant(sleepingValueHt: 97500),
        _dormant(productId: 'p2', name: 'Disjoncteur', sleepingValueHt: 2500),
      ],
    );

    expect(
      find.textContaining('${formatDA(100000)} immobilisés'),
      findsOneWidget,
    );
  });

  /// Le seuil part au SERVEUR : un filtre appliqué en masquant des lignes déjà
  /// chargées ferait mentir le total et le compte.
  testWidgets('changer le seuil de dormance redemande au serveur', (
    tester,
  ) async {
    final api = await _pump(tester, dormantRows: [_dormant()]);

    expect(api.dormantDays, [120]);

    await tester.tap(find.widgetWithText(ChoiceChip, '30 j'));
    await tester.pumpAndSettle();

    expect(api.dormantDays, [120, 30]);
  });

  testWidgets('les trois classements de la demande sont là, chacun nommé', (
    tester,
  ) async {
    await _pump(
      tester,
      demand: ProductDemand(
        bestSellers: [_line(revenueHt: 50000)],
        mostRequested: [_line(productId: 'p2', name: 'Disjoncteur')],
        unmetDemand: const [],
      ),
    );

    await tester.tap(find.text('On me réclame'));
    await tester.pumpAndSettle();

    expect(find.text('Les plus vendus'), findsOneWidget);
    expect(find.text('Les plus demandés au dépôt'), findsOneWidget);
    expect(find.text('Demandés et NON servis'), findsOneWidget);
    // Le chiffre d'affaires n'apparaît que sur les ventes.
    expect(find.text(formatDA(50000)), findsOneWidget);
    // Un classement vide le dit, au lieu de laisser un trou.
    expect(find.text('Rien sur la période.'), findsOneWidget);
  });

  testWidgets('changer la fenêtre de demande redemande au serveur', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      demand: ProductDemand(bestSellers: [_line(revenueHt: 1000)]),
    );

    await tester.tap(find.text('On me réclame'));
    await tester.pumpAndSettle();
    expect(api.demandDays, [30]);

    await tester.tap(find.widgetWithText(ChoiceChip, '90 j'));
    await tester.pumpAndSettle();

    expect(api.demandDays, [30, 90]);
  });

  /// Les valeurs proposées doivent tenir dans les bornes du serveur (7 à 730),
  /// sinon un bouton provoque un 400 — un piège pour l'utilisateur.
  ///
  /// Le test LIT les puces présentes au lieu d'énumérer des libellés attendus :
  /// autrement il resterait vert le jour où quelqu'un ajoute une puce « 3 j »,
  /// et il ne prouverait donc pas son titre.
  testWidgets('tous les seuils proposés sont dans les bornes du serveur', (
    tester,
  ) async {
    List<int> chipDays(WidgetTester tester) => tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .map((chip) => (chip.label as Text).data!)
        .map((label) => int.parse(label.replaceAll(' j', '')))
        .toList();

    await _pump(tester, demand: const ProductDemand());

    final dormant = chipDays(tester);
    expect(dormant, isNotEmpty);
    for (final days in dormant) {
      expect(days, inInclusiveRange(7, 730));
    }

    await tester.tap(find.text('On me réclame'));
    await tester.pumpAndSettle();

    final demand = chipDays(tester);
    expect(demand, isNotEmpty);
    for (final days in demand) {
      expect(days, inInclusiveRange(7, 730));
    }
  });

  /// C'est CE texte qui explique pourquoi un produit reçu hier est quand même
  /// dormant. Sans lui, on croit l'écran en retard.
  testWidgets('un mouvement plus récent que la vente est MONTRÉ', (
    tester,
  ) async {
    await _pump(
      tester,
      dormantRows: [
        _dormant(
          lastSoldAt: DateTime.utc(2026, 3, 2),
        ).copyWith(lastMovementAt: DateTime.utc(2026, 9, 25)),
      ],
    );

    expect(find.textContaining('dernier mouvement'), findsOneWidget);
  });

  testWidgets('un mouvement qui EST la vente n’est pas répété', (tester) async {
    await _pump(
      tester,
      dormantRows: [_dormant(lastSoldAt: DateTime.utc(2026, 3, 2))],
    );

    expect(find.textContaining('dernière vente'), findsOneWidget);
    expect(find.textContaining('dernier mouvement'), findsNothing);
  });

  /// Une liste tronquée doit le dire : sinon on décide sur une photo partielle en
  /// croyant tout voir.
  testWidgets('une liste tronquée annonce le total', (tester) async {
    final api = _FakeApi(dormantRows: [_dormant()]);
    useScreenSize(tester, const Size(900, 1400));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productReportsApiProvider.overrideWithValue(_TruncatedApi(api)),
          currentUserIdProvider.overrideWithValue('moi'),
        ],
        child: MaterialApp(
          theme: AppTheme.mobile(dark: true),
          home: const Scaffold(body: ProductReportsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('1 sur 137'), findsOneWidget);
  });

  group('accès à l’écran', () {
    List<String> labelsFor(AuthUser user) =>
        destinationsFor(user).map((d) => d.label).toList();

    test('« Rapports » suit `product.read`, pour les trois rôles', () {
      for (final role in ['ADMIN', 'VENDEUR', 'MAGASINIER']) {
        expect(
          labelsFor(
            authUser(
              id: 'u',
              fullName: 'Membre',
              roles: [role],
              permissions: const ['product.read'],
            ),
          ),
          contains('Rapports'),
          reason: 'le rôle $role doit y avoir accès',
        );
      }
    });

    test('sans `product.read`, pas de « Rapports »', () {
      expect(
        labelsFor(
          authUser(
            id: 'u',
            fullName: 'Membre',
            roles: const ['VENDEUR'],
            permissions: const ['sale.create'],
          ),
        ),
        isNot(contains('Rapports')),
      );
    });
  });
}
