import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/features/auth/application/auth_controller.dart';
import 'package:gestion_magasin/features/auth/presentation/login_screen.dart';
import 'package:gestion_magasin/ui/theme/ampere_colors.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';
import 'package:gestion_magasin/ui/widgets/screen_state.dart';

/// Contrôleur d'auth déjà résolu : sans lui, `build()` interrogerait le
/// stockage sécurisé (plugin natif absent en test) et l'écran resterait
/// bloqué en chargement, bouton désactivé.
class _SignedOutAuthController extends AuthController {
  @override
  Future<AuthState> build() async => const AuthSignedOut();
}

Widget _wrap(Widget child, {bool dark = true}) => ProviderScope(
  overrides: [
    authControllerProvider.overrideWith(_SignedOutAuthController.new),
  ],
  child: MaterialApp(
    theme: AppTheme.mobile(dark: dark),
    home: child,
  ),
);

void main() {
  group('LoginScreen', () {
    testWidgets('affiche les deux champs et le bouton', (tester) async {
      await tester.pumpWidget(_wrap(const LoginScreen()));
      await tester.pumpAndSettle();

      // Étiquette AU-DESSUS du champ, en capitales (AMPÈRE §6).
      expect(find.text('EMAIL OU TÉLÉPHONE'), findsOneWidget);
      expect(find.text('MOT DE PASSE'), findsOneWidget);
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

      final fields = tester.widgetList<TextField>(find.byType(TextField));
      // Identifiant en clair, mot de passe masqué.
      expect(fields.first.obscureText, isFalse);
      expect(fields.last.obscureText, isTrue);
    });

    testWidgets('rend aussi bien en thème clair', (tester) async {
      await tester.pumpWidget(_wrap(const LoginScreen(), dark: false));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(FilledButton, 'Se connecter'), findsOneWidget);
    });
  });

  group('SyncIndicator', () {
    testWidgets('affiche « Synchronisé » quand la file est vide', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const SyncIndicator(pendingCount: 0)));

      expect(find.text('Synchronisé'), findsOneWidget);
    });

    testWidgets('affiche le nombre exact de mutations en attente', (
      tester,
    ) async {
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
    testWidgets('rend chacun des états sans planter', (tester) async {
      for (final status in ScreenStatus.values) {
        await tester.pumpWidget(_wrap(ScreenStateView(status: status)));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'état $status');
      }
    });

    testWidgets('« aucun résultat » reprend le terme recherché', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ScreenStateView(
            status: ScreenStatus.noResults,
            searchTerm: 'benali',
          ),
        ),
      );

      expect(find.textContaining('benali'), findsOneWidget);
    });

    testWidgets('l’erreur garantit que la saisie est conservée', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const ScreenStateView(status: ScreenStatus.error)),
      );

      // §8 : dire ce qui s'est passé, pas le code technique.
      expect(find.textContaining('conservées'), findsOneWidget);
      expect(find.textContaining('500'), findsNothing);
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

    testWidgets('le chargement affiche des squelettes, pas une roue', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const ScreenStateView(status: ScreenStatus.loading)),
      );
      await tester.pump();

      expect(find.byType(AmpereSkeletonList), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('AmpereBadge', () {
    testWidgets('affiche TOUJOURS un libellé, jamais la couleur seule', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const AmpereBadge(label: 'Désactivé', tone: StatusTone.neutral)),
      );

      expect(find.text('Désactivé'), findsOneWidget);
    });
  });
}
