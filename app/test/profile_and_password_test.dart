import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/features/auth/application/auth_controller.dart';
import 'package:gestion_magasin/features/auth/data/auth_api.dart';
import 'package:gestion_magasin/features/auth/presentation/change_password_screen.dart';
import 'package:gestion_magasin/features/auth/presentation/profile_screen.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

Future<(FakeAuthApi, MemoryTokenStore)> _pump(
  WidgetTester tester,
  Widget screen, {
  int pending = 0,
  int foreignPending = 0,
}) async {
  useScreenSize(tester, const Size(420, 1000));
  final api = FakeAuthApi();
  final tokens = MemoryTokenStore();
  final db = AppDatabase.forTesting();
  addTearDown(db.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authApiProvider.overrideWithValue(api),
        tokenStoreProvider.overrideWithValue(tokens),
        appDatabaseProvider.overrideWithValue(db),
        pendingMutationsCountProvider.overrideWith((ref) => Stream.value(pending)),
        foreignPendingMutationsCountProvider.overrideWith(
          (ref) => Stream.value(foreignPending),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: screen),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (api, tokens);
}

AuthState? _auth(WidgetTester tester, Type screen) => ProviderScope.containerOf(
      tester.element(find.byType(screen)),
    ).read(authControllerProvider).value;

void main() {
  group('Mon profil', () {
    testWidgets('« Tout déconnecter » qui échoue : dit que la révocation n’a PAS eu lieu (I3)', (
      tester,
    ) async {
      final (api, tokens) = await _pump(tester, ProfileScreen(user: authUser()));
      api.logoutFailure = const ApiException(statusCode: 0, message: 'Serveur injoignable');

      await tester.tap(find.text('Déconnecter tous mes appareils'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tout déconnecter'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Révocation NON effectuée'), findsOneWidget);
      expect(_auth(tester, ProfileScreen), isA<AuthSignedIn>());
      expect(tokens.refresh, isNotNull);
    });

    testWidgets('se déconnecter avec des opérations en attente : prévient d’abord (I2)', (
      tester,
    ) async {
      final (api, _) = await _pump(tester, ProfileScreen(user: authUser()), pending: 2);

      final logout = find.text('Se déconnecter');
      await tester.ensureVisible(logout);
      await tester.tap(logout);
      await tester.pumpAndSettle();

      expect(find.text('Opérations non synchronisées'), findsOneWidget);
      expect(find.textContaining('2 opérations'), findsOneWidget);
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(api.logoutCalls, isEmpty);
      expect(_auth(tester, ProfileScreen), isA<AuthSignedIn>());
    });

    testWidgets('sans opération en attente : aucun dialogue superflu (§12.7)', (tester) async {
      final (api, _) = await _pump(tester, ProfileScreen(user: authUser()));

      final logout = find.text('Se déconnecter');
      await tester.ensureVisible(logout);
      await tester.tap(logout);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(api.logoutCalls, [false]);
    });

    testWidgets('signale les opérations laissées par un AUTRE compte sur l’appareil', (
      tester,
    ) async {
      await _pump(tester, ProfileScreen(user: authUser()), foreignPending: 3);

      expect(find.textContaining('par un autre compte'), findsOneWidget);
      expect(find.textContaining('jamais avec votre session'), findsOneWidget);
    });
  });

  group('Changement de mot de passe', () {
    testWidgets('mauvais mot de passe ACTUEL : message exact, saisie conservée (C9)', (
      tester,
    ) async {
      final (api, _) = await _pump(tester, const ChangePasswordScreen(forced: false));
      api.changePasswordFailure = const ApiException(
        statusCode: 403,
        message: 'Mot de passe actuel incorrect',
        code: 'CURRENT_PASSWORD_INVALID',
      );

      await tester.enterText(find.byType(TextFormField).at(0), 'PasLeBon1');
      await tester.enterText(find.byType(TextFormField).at(1), 'Nouveau12345');
      await tester.enterText(find.byType(TextFormField).at(2), 'Nouveau12345');
      final submit = find.widgetWithText(FilledButton, 'Valider');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      // Pas « Identifiant ou mot de passe incorrect » : ce n'est pas un login.
      expect(find.text('Mot de passe actuel incorrect'), findsOneWidget);
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      expect(_auth(tester, ChangePasswordScreen), isA<AuthSignedIn>());
    });

    testWidgets('les champs de mot de passe ne sont ni corrigés ni suggérés', (tester) async {
      await _pump(tester, const ChangePasswordScreen(forced: false));

      for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
        expect(field.autocorrect, isFalse);
        expect(field.enableSuggestions, isFalse);
      }
    });
  });
}
