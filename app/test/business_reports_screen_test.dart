import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/money.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/business_reports/application/business_reports_controller.dart';
import 'package:gestion_magasin/features/business_reports/data/business_report_models.dart';
import 'package:gestion_magasin/features/business_reports/data/business_reports_api.dart';
import 'package:gestion_magasin/features/business_reports/presentation/business_reports_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

/// Rapports d'activité (P1 n°21) : un résumé pour l'admin seul.
class _FakeApi extends BusinessReportsApi {
  _FakeApi({this.salesData, this.stockData, this.purchasesData}) : super(Dio());

  SalesReport? salesData;
  StockReport? stockData;
  PurchasesReport? purchasesData;

  final salesRanges = <String>[];
  final stockCalls = <int>[];

  @override
  Future<SalesReport> sales({String? from, String? to}) async {
    salesRanges.add('$from..$to');
    return salesData ?? _emptySales;
  }

  @override
  Future<StockReport> stock() async {
    stockCalls.add(stockCalls.length);
    return stockData ?? const StockReport();
  }

  @override
  Future<PurchasesReport> purchases({String? from, String? to}) async {
    return purchasesData ?? const PurchasesReport(period: _period);
  }
}

const _period = ReportPeriod(from: '2026-08-28', to: '2026-09-26', days: 30);

final _emptySales = SalesReport(
  period: _period,
  totals: const SalesReportTotals(),
);

Future<_FakeApi> _pump(
  WidgetTester tester, {
  SalesReport? sales,
  StockReport? stock,
  PurchasesReport? purchases,
}) async {
  useScreenSize(tester, const Size(1000, 1600));
  final api = _FakeApi(
    salesData: sales,
    stockData: stock,
    purchasesData: purchases,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        businessReportsApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue('chef'),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: const Scaffold(body: BusinessReportsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('les ventes affichent CA, TVA et période appliquée', (
    tester,
  ) async {
    await _pump(
      tester,
      sales: SalesReport(
        period: _period,
        totals: const SalesReportTotals(
          count: 12,
          revenueHt: 250_000,
          taxAmount: 47_500,
          revenueTtc: 297_500,
          costHt: 150_000,
          marginHt: 100_000,
        ),
      ),
    );

    expect(find.text('12'), findsOneWidget);
    expect(find.text(formatDA(250_000)), findsOneWidget);
    expect(find.text(formatDA(100_000)), findsOneWidget);
    // La période vient de la RÉPONSE, pas de l'écran.
    expect(find.textContaining('2026-08-28'), findsOneWidget);
  });

  /// Une marge égale au CA serait un chiffre faux et flatteur : l'écran doit
  /// afficher « — » ET dire pourquoi.
  testWidgets('marge inconnue : « — » et la raison, jamais 0 DA', (
    tester,
  ) async {
    await _pump(
      tester,
      sales: SalesReport(
        period: _period,
        totals: const SalesReportTotals(revenueHt: 80_000),
      ),
    );

    // La MARGE affiche « — », et l'écran dit pourquoi.
    final marge = find.ancestor(
      of: find.text('Marge HT'),
      matching: find.byType(Column),
    );
    expect(
      find.descendant(of: marge.first, matching: find.text('—')),
      findsOneWidget,
    );
    expect(find.text('coût d’achat inconnu'), findsOneWidget);
    // Pas d'assertion globale « aucun 0,00 DA » : une TVA nulle ou des achats à
    // zéro sur la période SONT des zéros légitimes. Ce qui ne doit jamais valoir
    // zéro, c'est l'inconnu — et c'est ce qui est vérifié ci-dessus.
  });

  testWidgets('la ventilation par catégorie nomme celle qui manque', (
    tester,
  ) async {
    await _pump(
      tester,
      sales: SalesReport(
        period: _period,
        totals: const SalesReportTotals(revenueHt: 11_000),
        byCategory: const [
          SalesByCategory(
            categoryId: 'c1',
            categoryName: 'Câbles',
            revenueHt: 8_000,
            quantity: '20.000',
          ),
          SalesByCategory(
            categoryName: 'Sans catégorie',
            revenueHt: 3_000,
            quantity: '5.000',
          ),
        ],
      ),
    );

    expect(find.text('Câbles'), findsOneWidget);
    expect(find.text('Sans catégorie'), findsOneWidget);
  });

  testWidgets('le stock annonce les références sans coût, hors total', (
    tester,
  ) async {
    await _pump(
      tester,
      stock: const StockReport(
        referenceCount: 40,
        valueHt: 500_000,
        withoutCostCount: 3,
        lowCount: 5,
        outOfStockCount: 2,
        byLocation: [
          StockByLocation(
            locationId: 'l1',
            locationName: 'Magasin',
            locationType: 'MAGASIN',
            referenceCount: 25,
            valueHt: 300_000,
          ),
        ],
      ),
    );

    expect(find.text(formatDA(500_000)), findsOneWidget);
    expect(
      find.textContaining('3 référence(s) sans coût connu'),
      findsOneWidget,
    );
    expect(find.text('Magasin'), findsOneWidget);
  });

  /// Le stock est un ÉTAT : changer la période ne doit pas le relire, sinon on
  /// laisse croire que sa valeur dépend de la fenêtre.
  testWidgets('changer la période relit les ventes, PAS le stock', (
    tester,
  ) async {
    final api = await _pump(tester);

    expect(api.salesRanges, hasLength(1));
    expect(api.stockCalls, hasLength(1));

    await tester.tap(find.widgetWithText(ChoiceChip, '90 j'));
    await tester.pumpAndSettle();

    expect(api.salesRanges, hasLength(2));
    expect(api.salesRanges.first, isNot(api.salesRanges.last));
    expect(api.stockCalls, hasLength(1));
  });

  testWidgets('les achats disent que commandé et reçu ne s’équilibrent pas', (
    tester,
  ) async {
    await _pump(
      tester,
      purchases: const PurchasesReport(
        period: _period,
        orderCount: 4,
        orderedHt: 400_000,
        receivedHt: 120_000,
        receptionCount: 2,
        bySupplier: [
          PurchasesBySupplier(
            supplierId: 's1',
            supplierName: 'Sonelec',
            orderCount: 2,
            orderedHt: 300_000,
            receivedHt: 100_000,
          ),
        ],
      ),
    );

    expect(find.text(formatDA(400_000)), findsOneWidget);
    expect(find.text(formatDA(120_000)), findsOneWidget);
    expect(find.textContaining('ne s’équilibrent pas'), findsOneWidget);
    expect(find.text('Sonelec'), findsOneWidget);
  });

  group('fenêtre demandée', () {
    test('bornes incluant aujourd’hui, `to` étant inclusif côté serveur', () {
      final range = rangeFor(7, now: DateTime(2026, 9, 26, 15, 30));
      expect(range.to, '2026-09-26');
      // 7 jours révolus, aujourd'hui compris : du 20 au 26.
      expect(range.from, '2026-09-20');
    });

    test('une fenêtre d’un jour ne remonte pas dans le passé', () {
      final range = rangeFor(1, now: DateTime(2026, 9, 26));
      expect(range.from, range.to);
    });
  });

  group('accès à l’écran', () {
    List<String> labelsFor(AuthUser user) =>
        destinationsFor(user).map((d) => d.label).toList();

    /// Miroir du guard serveur : ADMIN seul. Ces rapports portent CA, marge et
    /// valeur du stock au coût.
    test('« Activité » est réservé à l’ADMIN', () {
      expect(
        labelsFor(
          authUser(
            id: 'chef',
            fullName: 'Radhi',
            roles: const ['ADMIN'],
            permissions: const ['product.read'],
          ),
        ),
        contains('Activité'),
      );
      for (final role in ['VENDEUR', 'MAGASINIER']) {
        expect(
          labelsFor(
            authUser(
              id: 'u',
              fullName: 'Membre',
              roles: [role],
              permissions: const ['product.read'],
            ),
          ),
          isNot(contains('Activité')),
          reason: 'le rôle $role ne doit pas voir les rapports d’activité',
        );
      }
    });

    /// Les deux familles ne se confondent pas : fermer « Activité » ne doit pas
    /// fermer « Rapports » (produits), ouvert aux trois rôles.
    test('« Rapports » (produits) reste ouvert au vendeur', () {
      expect(
        labelsFor(
          authUser(
            id: 'v',
            fullName: 'Amine',
            roles: const ['VENDEUR'],
            permissions: const ['product.read'],
          ),
        ),
        contains('Rapports'),
      );
    });
  });
}
