import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/features/auth/application/auth_controller.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_repository.dart';
import 'package:gestion_magasin/features/users/data/users_api.dart';
import 'package:gestion_magasin/ui/adaptive_shell.dart';
import 'package:gestion_magasin/ui/desktop/desktop_shell.dart';
import 'package:gestion_magasin/ui/mobile/mobile_shell.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

class _SignedIn extends AuthController {
  _SignedIn(this.user);
  final AuthUser user;

  @override
  Future<AuthState> build() async => AuthSignedIn(user);
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required AuthUser user,
  required Size size,
  bool reachable = true,
  CatalogRepository? catalog,
}) async {
  useScreenSize(tester, size);
  final db = AppDatabase.forTesting();
  addTearDown(db.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => _SignedIn(user)),
        appDatabaseProvider.overrideWithValue(db),
        usersApiProvider.overrideWithValue(
          FakeUsersApi(users: [managedUser()]),
        ),
        // Les flux Drift réels ne se résolvent pas dans le temps simulé des
        // tests d'écran ; la file elle-même est testée à part.
        pendingMutationsCountProvider.overrideWith((ref) => Stream.value(0)),
        foreignPendingMutationsCountProvider.overrideWith(
          (ref) => Stream.value(0),
        ),
        rejectedMutationsProvider.overrideWith((ref) => Stream.value(const [])),
        if (!reachable) serverReachableProvider.overrideWith(_Unreachable.new),
        if (catalog != null)
          catalogRepositoryProvider.overrideWithValue(catalog),
      ],
      child: MaterialApp(
        theme: size.width >= 768
            ? AppTheme.desktop(dark: true)
            : AppTheme.mobile(dark: true),
        home: const AdaptiveShell(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Unreachable extends ServerReachability {
  @override
  bool build() => false;
}

class _CountingCatalog implements CatalogRepository {
  int pulls = 0;

  @override
  Future<void> pull() async => pulls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'connexion : la coquille lance la synchro du catalogue sans ouvrir l’écran Catalogue',
    (tester) async {
      final catalog = _CountingCatalog();
      await _pumpShell(
        tester,
        user: authUser(
          roles: const ['VENDEUR'],
          permissions: const ['sale.create'],
        ),
        size: const Size(400, 800),
        catalog: catalog,
      );
      expect(find.text('Accueil'), findsWidgets);
      expect(catalog.pulls, 1);
    },
  );

  group('menu dérivé des droits (miroir des guards serveur)', () {
    testWidgets('un VENDEUR ne voit pas « Utilisateurs »', (tester) async {
      await _pumpShell(
        tester,
        user: authUser(
          roles: const ['VENDEUR'],
          permissions: const ['sale.create'],
        ),
        size: const Size(400, 800),
      );

      expect(find.text('Utilisateurs'), findsNothing);
      expect(find.text('Mon profil'), findsWidgets);
    });

    testWidgets(
      'un ADMIN SANS la permission user.manage ne le voit pas non plus',
      (tester) async {
        await _pumpShell(
          tester,
          user: authUser(permissions: const []),
          size: const Size(1300, 900),
        );

        expect(find.text('Utilisateurs'), findsNothing);
      },
    );

    testWidgets('un ADMIN avec user.manage le voit', (tester) async {
      await _pumpShell(tester, user: authUser(), size: const Size(1300, 900));

      expect(find.text('Utilisateurs'), findsOneWidget);
    });
  });

  testWidgets(
    'mobile : UNE seule barre d’en-tête sur l’onglet Utilisateurs (C10)',
    (tester) async {
      await _pumpShell(tester, user: authUser(), size: const Size(400, 800));

      await tester.tap(find.text('Utilisateurs'));
      await tester.pumpAndSettle();

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Amine Benali'), findsOneWidget);
    },
  );

  group('points de rupture AMPÈRE §9', () {
    testWidgets('< 768 : coquille mobile à onglets', (tester) async {
      await _pumpShell(tester, user: authUser(), size: const Size(700, 900));

      expect(find.byType(MobileShell), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('768-1180 : desktop avec sidebar en rail de 64 px', (
      tester,
    ) async {
      await _pumpShell(tester, user: authUser(), size: const Size(1000, 800));

      final shell = tester.widget<DesktopShell>(find.byType(DesktopShell));
      expect(shell.compact, isTrue);
      // En rail, les libellés passent en infobulle.
      expect(find.byTooltip('Utilisateurs'), findsOneWidget);
    });

    testWidgets('≥ 1180 : sidebar complète', (tester) async {
      await _pumpShell(tester, user: authUser(), size: const Size(1300, 900));

      expect(
        tester.widget<DesktopShell>(find.byType(DesktopShell)).compact,
        isFalse,
      );
      expect(find.text('Gestion magasin'), findsOneWidget);
    });
  });

  testWidgets(
    'mobile : au-delà de 4 destinations, « Plus » liste les suivantes (§7)',
    (tester) async {
      await _pumpShell(
        tester,
        user: authUser(
          permissions: const [
            'user.manage',
            'product.read',
            'stock.read.store',
          ],
        ),
        size: const Size(400, 800),
      );

      // Accueil, Catalogue, Stock + Plus : 4 onglets, jamais 5.
      expect(find.byType(NavigationDestination), findsNWidgets(4));
      expect(find.text('Plus'), findsOneWidget);
      expect(find.text('Utilisateurs'), findsNothing);

      await tester.tap(find.text('Plus'));
      await tester.pumpAndSettle();
      expect(find.text('Utilisateurs'), findsOneWidget);
      expect(find.text('Mon profil'), findsOneWidget);

      await tester.tap(find.text('Mon profil'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Mon profil'), findsOneWidget);
    },
  );

  testWidgets('serveur injoignable : l’en-tête affiche « Hors ligne »', (
    tester,
  ) async {
    await _pumpShell(
      tester,
      user: authUser(),
      size: const Size(1300, 900),
      reachable: false,
    );

    expect(find.text('Hors ligne'), findsOneWidget);
  });
}
