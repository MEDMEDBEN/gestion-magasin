import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/money.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/home/data/dashboard_api.dart';
import 'package:gestion_magasin/features/home/data/dashboard_models.dart';
import 'package:gestion_magasin/features/home/presentation/home_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

/// Accueil (P1 n°15) : ce qu'il montre vient du serveur, bloc par bloc. Un bloc
/// absent = interdit à ce compte, et l'écran n'invente pas un zéro à sa place.
AuthUser _vendeur() => authUser(
  id: 'v',
  fullName: 'Nadia Kaci',
  roles: const ['VENDEUR'],
  permissions: const [
    'sale.create',
    'product.read',
    'stock.read.store',
    'customer.read',
    'planning.task.read',
    'transfer.request',
  ],
);

Future<FakeDashboardApi> _pump(
  WidgetTester tester, {
  required AuthUser user,
  DashboardSummary? summary,
  ApiException? failure,
  Size size = const Size(500, 1400),
}) async {
  useScreenSize(tester, size);
  final api = FakeDashboardApi(
    result: summary ?? const DashboardSummary(day: '2026-09-23'),
    failure: failure,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [dashboardApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: HomeScreen(user: user)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('un bloc absent n’affiche RIEN, pas un zéro', (tester) async {
    await _pump(
      tester,
      user: _vendeur(),
      // Ce que le serveur rend à un vendeur : ni fournisseurs ni achats.
      summary: const DashboardSummary(
        day: '2026-09-23',
        sales: DashboardSales(count: 3, revenueTtc: 145000),
        tasks: DashboardTasks(open: 2, late: 1),
      ),
    );

    expect(find.text('Chiffre d’affaires du jour'), findsOneWidget);
    expect(find.text('3 vente(s) validée(s)'), findsOneWidget);
    expect(find.text('Dettes fournisseurs'), findsNothing);
    expect(find.text('Commandes à recevoir'), findsNothing);
    expect(find.text('Alertes de stock'), findsNothing);
  });

  testWidgets('les montants sont formatés en dinars, jamais en centimes', (
    tester,
  ) async {
    await _pump(
      tester,
      user: _vendeur(),
      summary: const DashboardSummary(
        day: '2026-09-23',
        sales: DashboardSales(count: 1, revenueTtc: 145000),
        customers: DashboardCustomers(debt: 250000, overdue: 50000),
      ),
    );

    expect(find.text('145000'), findsNothing);
    expect(find.text(formatDA(145000)), findsOneWidget);
    expect(find.text('${formatDA(50000)} en retard'), findsOneWidget);
  });

  testWidgets('une alerte de stock nomme les produits à réapprovisionner', (
    tester,
  ) async {
    await _pump(
      tester,
      user: _vendeur(),
      summary: const DashboardSummary(
        day: '2026-09-23',
        stock: DashboardStock(
          lowCount: 1,
          outOfStockCount: 2,
          low: [
            DashboardLowStock(
              productId: 'p1',
              name: 'Câble 2,5 mm²',
              quantity: '3.000',
              minThreshold: '10.000',
            ),
          ],
        ),
      ),
    );

    expect(find.text('Alertes de stock'), findsOneWidget);
    expect(find.text('2 en rupture'), findsOneWidget);
    expect(find.text('Câble 2,5 mm²'), findsOneWidget);
    expect(find.text('Reste 3.000 · seuil 10.000'), findsOneWidget);
  });

  testWidgets(
    'hors ligne : le résumé manque, les raccourcis restent utilisables',
    (tester) async {
      await _pump(
        tester,
        user: _vendeur(),
        failure: const ApiException(statusCode: 0, message: 'hors ligne'),
      );

      expect(find.textContaining('Hors ligne'), findsOneWidget);
      // Ce qui compte : on peut encore vendre (la vente marche hors ligne).
      expect(find.text('Nouvelle vente'), findsOneWidget);
    },
  );

  testWidgets('un raccourci DEMANDE la destination à la coquille', (
    tester,
  ) async {
    late WidgetRef capturedRef;
    useScreenSize(tester, const Size(500, 1400));
    final api = FakeDashboardApi(
      result: const DashboardSummary(day: '2026-09-23'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          theme: AppTheme.mobile(dark: true),
          home: Consumer(
            builder: (context, ref, _) {
              capturedRef = ref;
              return Scaffold(body: HomeScreen(user: _vendeur()));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(capturedRef.read(requestedDestinationProvider), isNull);
    await tester.tap(find.text('Nouvelle vente'));
    await tester.pump();

    expect(capturedRef.read(requestedDestinationProvider), 'Vente');
  });

  testWidgets('« Réessayer » relit vraiment le résumé', (tester) async {
    final api = await _pump(
      tester,
      user: _vendeur(),
      failure: const ApiException(statusCode: 0, message: 'hors ligne'),
    );
    // Compte RELATIF : hors test, l'état de session et le réseau relisent déjà
    // le résumé ; ce qui est en cause ici, c'est que le bouton en redemande un.
    final avant = api.calls;
    expect(avant, greaterThan(0));

    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();

    expect(api.calls, greaterThan(avant));
  });

  testWidgets('aucun bloc autorisé : l’écran le DIT au lieu de rester vide', (
    tester,
  ) async {
    await _pump(
      tester,
      user: authUser(id: 'x', roles: const ['VENDEUR'], permissions: const []),
      summary: const DashboardSummary(day: '2026-09-23'),
    );

    expect(find.text('Rien à résumer'), findsOneWidget);
    // Aucun droit d'écran : aucun raccourci ne doit être proposé non plus.
    expect(find.text('Nouvelle vente'), findsNothing);
    expect(find.text('Transferts'), findsNothing);
  });

  /// Le bloc `purchases` est gardé serveur par `reception.create`, alors que
  /// l'écran Achats exige `purchase.create` : avec le cumul de rôles, les deux
  /// ne coïncident pas toujours, et une carte qui n'ouvre rien est un piège.
  testWidgets('une carte ne renvoie pas vers un écran fermé à ce compte', (
    tester,
  ) async {
    late WidgetRef capturedRef;
    useScreenSize(tester, const Size(500, 1400));
    final api = FakeDashboardApi(
      result: const DashboardSummary(
        day: '2026-09-23',
        purchases: DashboardPurchases(toReceive: 3),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          theme: AppTheme.mobile(dark: true),
          home: Consumer(
            builder: (context, ref, _) {
              capturedRef = ref;
              return Scaffold(
                // Il réceptionne, mais ne crée pas de commande : pas d'écran
                // « Achats » dans son menu.
                body: HomeScreen(
                  user: authUser(
                    id: 'm',
                    roles: const ['MAGASINIER'],
                    permissions: const ['reception.create'],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Commandes à recevoir'), findsOneWidget);
    await tester.tap(find.text('Commandes à recevoir'));
    await tester.pump();

    expect(capturedRef.read(requestedDestinationProvider), isNull);
  });
}
