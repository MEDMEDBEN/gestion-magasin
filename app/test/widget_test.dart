import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/features/auth/application/auth_controller.dart';
import 'package:gestion_magasin/features/auth/presentation/login_screen.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';
import 'package:gestion_magasin/ui/widgets/screen_state.dart';

/// Contrôleur d'auth déjà résolu : sans lui, `build()` interrogerait le
/// stockage sécurisé (plugin natif absent en test) et l'écran resterait
/// bloqué en chargement, bouton désactivé.
class _SignedOutAuthController extends AuthController {
  @override
  Future<AuthState> build() async => const AuthSignedOut();
}

Widget _wrap(Widget child) => ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(_SignedOutAuthController.new),
      ],
      child: MaterialApp(theme: AppTheme.dark(), home: child),
    );

void main() {
  group('LoginScreen', () {
    testWidgets('affiche les deux champs et le bouton', (tester) async {
      await tester.pumpWidget(_wrap(const LoginScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Email ou téléphone'), findsOneWidget);
      expect(find.text('Mot de passe'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Se connecter'), findsOneWidget);
    });

    testWidgets('rappelle qu’il n’y a pas d’inscription publique', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const LoginScreen()));
      await tester.pumpAndSettle();

      expect(
        find.text("Votre compte est créé par l'administrateur."),
        findsOneWidget,
      );
    });

    testWidgets('refuse de soumettre un formulaire vide', (tester) async {
      await tester.pumpWidget(_wrap(const LoginScreen()));
      await tester.pumpAndSettle();

      // L'écran de test est étroit : on fait défiler jusqu'au bouton avant de
      // le toucher, sinon il est hors de la zone tactile.
      final button = find.widgetWithText(FilledButton, 'Se connecter');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pump();

      expect(find.text('Saisissez votre identifiant'), findsOneWidget);
      expect(find.text('Saisissez votre mot de passe'), findsOneWidget);
    });

    testWidgets('masque le mot de passe par défaut', (tester) async {
      await tester.pumpWidget(_wrap(const LoginScreen()));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.ancestor(
            of: find.text('Mot de passe'),
            matching: find.byType(TextFormField),
          ),
          matching: find.byType(TextField),
        ),
      );
      expect(field.obscureText, isTrue);
    });
  });

  group('SyncIndicator', () {
    testWidgets('affiche « Synchronisé » quand la file est vide', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const SyncIndicator(pendingCount: 0)));

      expect(find.text('Synchronisé'), findsOneWidget);
    });

    testWidgets('affiche le nombre de mutations en attente', (tester) async {
      await tester.pumpWidget(_wrap(const SyncIndicator(pendingCount: 3)));

      expect(find.text('3 en attente'), findsOneWidget);
    });

    testWidgets('un rejet prime sur tout le reste', (tester) async {
      await tester.pumpWidget(
        _wrap(const SyncIndicator(pendingCount: 5, rejectedCount: 2)),
      );

      expect(find.text('2 échouées'), findsOneWidget);
    });

    testWidgets('signale l’état hors ligne', (tester) async {
      await tester.pumpWidget(
        _wrap(const SyncIndicator(pendingCount: 1, isOffline: true)),
      );

      expect(find.text('Hors ligne'), findsOneWidget);
    });
  });

  group('ScreenStateView', () {
    testWidgets('rend chacun des 6 états sans planter', (tester) async {
      for (final status in ScreenStatus.values) {
        await tester.pumpWidget(_wrap(ScreenStateView(status: status)));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'état $status');
      }
    });

    testWidgets('propose de réessayer sur erreur', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        _wrap(
          ScreenStateView(
            status: ScreenStatus.error,
            onRetry: () => retried = true,
          ),
        ),
      );

      await tester.tap(find.text('Réessayer'));
      expect(retried, isTrue);
    });
  });
}
