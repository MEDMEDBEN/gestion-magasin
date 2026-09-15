import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/features/users/application/users_controller.dart';
import 'package:gestion_magasin/features/users/data/users_api.dart';
import 'package:gestion_magasin/features/users/presentation/users_screen.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';
import 'package:gestion_magasin/ui/widgets/ampere_controls.dart';
import 'package:gestion_magasin/ui/widgets/screen_state.dart';

import 'support/fakes.dart';

Widget _wrap(
  FakeUsersApi api, {
  String? initialSearch,
  bool desktop = false,
  double textScale = 1,
}) {
  return ProviderScope(
    overrides: [
      usersApiProvider.overrideWithValue(api),
      currentUserIdProvider.overrideWithValue('me'),
      if (initialSearch != null)
        userSearchProvider.overrideWith(() => _SeededSearch(initialSearch)),
    ],
    child: MaterialApp(
      theme: desktop
          ? AppTheme.desktop(dark: true)
          : AppTheme.mobile(dark: true),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      // Hébergé comme dans une coquille : un Scaffold SANS AppBar.
      home: const Scaffold(body: UsersScreen()),
    ),
  );
}

class _SeededSearch extends UserSearchController {
  _SeededSearch(this.seed);
  final String seed;

  @override
  String build() => seed;
}

void main() {
  group('liste mobile', () {
    setUp(() {});

    testWidgets('affiche les comptes avec leurs rôles traduits', (
      tester,
    ) async {
      useScreenSize(tester, const Size(400, 800));
      final api = FakeUsersApi(
        users: [
          managedUser(),
          managedUser(
            id: 'u2',
            fullName: 'Karim Saidi',
            roles: const ['MAGASINIER', 'VENDEUR'],
          ),
        ],
      );

      await tester.pumpWidget(_wrap(api));
      await tester.pumpAndSettle();

      expect(find.text('Amine Benali'), findsOneWidget);
      expect(find.text('Karim Saidi'), findsOneWidget);
      // Rôles cumulés : tous affichés, traduits.
      expect(find.text('Vendeur / Caissier'), findsNWidgets(2));
      expect(find.text('Magasinier'), findsOneWidget);
      // Aucun tableau sur mobile (§9).
      expect(find.text('DERNIÈRE CONNEXION'), findsNothing);
    });

    testWidgets(
      'signale un compte désactivé et un mot de passe temporaire par un LIBELLÉ',
      (tester) async {
        useScreenSize(tester, const Size(400, 800));
        final api = FakeUsersApi(
          users: [managedUser(isActive: false, mustChangePassword: true)],
        );

        await tester.pumpWidget(_wrap(api));
        await tester.pumpAndSettle();

        expect(find.text('Désactivé'), findsOneWidget);
        expect(find.text('Mot de passe temporaire'), findsOneWidget);
      },
    );
  });

  testWidgets('desktop : tableau dense avec en-tête et dernière connexion', (
    tester,
  ) async {
    useScreenSize(tester, const Size(1300, 900));
    final api = FakeUsersApi(
      users: [managedUser(lastLoginAt: DateTime(2026, 9, 5, 8, 14))],
    );

    await tester.pumpWidget(_wrap(api, desktop: true));
    await tester.pumpAndSettle();

    expect(find.text('COMPTE'), findsOneWidget);
    expect(find.text('DERNIÈRE CONNEXION'), findsOneWidget);
    expect(find.text('05/09/2026 08:14'), findsOneWidget);
    expect(find.text('Actif'), findsOneWidget);
  });

  testWidgets('liste vide : UN SEUL bouton primaire à l’écran (§6)', (
    tester,
  ) async {
    useScreenSize(tester, const Size(400, 800));
    await tester.pumpWidget(_wrap(FakeUsersApi()));
    await tester.pumpAndSettle();

    expect(find.text('Aucun utilisateur'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('recherche sans résultat : reprend le terme cherché', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(FakeUsersApi(users: [managedUser()]), initialSearch: 'zzz'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Aucun résultat'), findsOneWidget);
    expect(find.textContaining('zzz'), findsOneWidget);
  });

  testWidgets('hors ligne : le dit, et propose de réessayer', (tester) async {
    final api = FakeUsersApi()
      ..failure = const ApiException(
        statusCode: 0,
        message: 'Serveur injoignable',
      );

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.text('Hors connexion'), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
  });

  testWidgets('erreur serveur : état d’erreur, saisie garantie', (
    tester,
  ) async {
    final api = FakeUsersApi()
      ..failure = const ApiException(
        statusCode: 500,
        message: 'Erreur interne du serveur',
      );

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.byType(ScreenStateView), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
  });

  testWidgets('au-delà de 50 comptes, « Afficher plus » charge la suite', (
    tester,
  ) async {
    useScreenSize(tester, const Size(1300, 900));
    final api = FakeUsersApi(
      users: [
        for (var i = 0; i < 120; i++)
          managedUser(id: 'u$i', fullName: 'Membre $i'),
      ],
    );

    await tester.pumpWidget(_wrap(api, desktop: true));
    await tester.pumpAndSettle();
    expect(find.text('50 affichés sur 120 comptes'), findsOneWidget);

    final more = find.text('Afficher plus');
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();

    expect(api.requestedPages, [1, 2]);
    expect(find.text('100 affichés sur 120 comptes'), findsOneWidget);
  });

  testWidgets('un rechargement garde la liste affichée (pas de squelette)', (
    tester,
  ) async {
    final api = FakeUsersApi(users: [managedUser()]);
    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(UsersScreen)),
    );
    container.read(usersControllerProvider.notifier).refresh();
    await tester.pump();

    expect(find.byType(AmpereSkeletonList), findsNothing);
    expect(find.text('Amine Benali'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('sur SON compte, le menu ne propose que « Modifier »', (
    tester,
  ) async {
    useScreenSize(tester, const Size(400, 800));
    final api = FakeUsersApi(
      users: [
        managedUser(id: 'me', fullName: 'Moi Admin', roles: const ['ADMIN']),
      ],
    );

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Actions'));
    await tester.pumpAndSettle();

    expect(find.text('Modifier'), findsOneWidget);
    expect(find.text('Désactiver'), findsNothing);
    expect(find.text('Réinitialiser le mot de passe'), findsNothing);
  });

  testWidgets('désactiver un compte : confirmation en style Danger (§6)', (
    tester,
  ) async {
    useScreenSize(tester, const Size(400, 800));
    final api = FakeUsersApi(users: [managedUser()]);

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Désactiver'));
    await tester.pumpAndSettle();

    final confirm = find.widgetWithText(AmpereDangerButton, 'Désactiver');
    expect(confirm, findsOneWidget);
    // Jamais un bouton rempli pour confirmer une destruction.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
      findsNothing,
    );

    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(api.updates.single.$2, {'isActive': false});
  });

  testWidgets('le menu d’actions reste lisible au zoom texte 200 % (§12)', (
    tester,
  ) async {
    useScreenSize(tester, const Size(400, 800));
    final api = FakeUsersApi(users: [managedUser()]);

    await tester.pumpWidget(_wrap(api, textScale: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Actions').first);
    await tester.pumpAndSettle();

    expect(find.text('Réinitialiser le mot de passe'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
