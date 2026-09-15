import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/ui/theme/ampere_colors.dart';
import 'package:gestion_magasin/ui/theme/ampere_typography.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';
import 'package:gestion_magasin/ui/theme/theme_controller.dart';
import 'package:gestion_magasin/ui/widgets/ampere_controls.dart';

/// Compte connecté pilotable par le test.
class _TestUser extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? id) => state = id;
}

final _testUser = NotifierProvider<_TestUser, String?>(_TestUser.new);

void main() {
  group('thème persisté PAR UTILISATEUR (§2)', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = AppDatabase.forTesting();
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          currentUserIdProvider.overrideWith((ref) => ref.watch(_testUser)),
        ],
      );
      // Le thème est écouté en permanence par l'app (MaterialApp).
      container.listen(themeModeProvider, (_, _) {});
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 20));

    test('chacun retrouve SON thème sur le poste partagé', () async {
      container.read(_testUser.notifier).set('compte-a');
      await container.read(themeModeProvider.notifier).set(ThemeMode.light);

      container.read(_testUser.notifier).set('compte-b');
      await settle();
      expect(
        container.read(themeModeProvider),
        ThemeMode.dark,
        reason: 'défaut sombre',
      );

      container.read(_testUser.notifier).set('compte-a');
      await settle();
      expect(container.read(themeModeProvider), ThemeMode.light);
    });

    test(
      'un choix fait PENDANT la lecture n’est pas écrasé par elle (course)',
      () async {
        await container
            .read(localSettingsStoreProvider)
            .write('theme_mode.compte-a', 'light');

        container.read(_testUser.notifier).set('compte-a');
        container.read(themeModeProvider); // lance la lecture asynchrone…
        await container
            .read(themeModeProvider.notifier)
            .set(ThemeMode.dark); // …et on choisit
        await settle();

        expect(container.read(themeModeProvider), ThemeMode.dark);
      },
    );
  });

  group('focus clavier TOUJOURS visible (§6, §12.10)', () {
    test('les boutons portent un anneau 2 px accent au focus', () {
      final theme = AppTheme.desktop(dark: true);
      final accent = AmpereColors.desktopDark.accent;

      for (final style in [
        theme.filledButtonTheme.style!,
        theme.outlinedButtonTheme.style!,
        theme.textButtonTheme.style!,
        theme.iconButtonTheme.style!,
      ]) {
        final focused = style.side!.resolve({WidgetState.focused})!;
        expect(focused.width, 2);
        expect(focused.color, accent);
        // Tracé à l'extérieur : visible même sur un bouton rempli d'accent.
        expect(focused.strokeAlign, BorderSide.strokeAlignOutside);
      }
    });

    testWidgets(
      'une zone cliquable affiche son contour quand elle a le focus',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.desktop(dark: true),
            home: Scaffold(
              body: AmpereTappable(
                onTap: () {},
                borderRadius: 8,
                child: const SizedBox(
                  width: 200,
                  height: 40,
                  child: Text('Ligne'),
                ),
              ),
            ),
          ),
        );

        Decoration? ring() => tester
            .widget<Container>(
              find.descendant(
                of: find.byType(AmpereTappable),
                matching: find.byType(Container),
              ),
            )
            .foregroundDecoration;

        expect(ring(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();

        final border = (ring()! as BoxDecoration).border! as Border;
        expect(border.top.width, 2);
        expect(border.top.color, AmpereColors.desktopDark.accent);
      },
    );
  });

  group('police Archivo partout (§3)', () {
    test('chaque style AMPÈRE porte explicitement la famille', () {
      for (final style in [
        AmpereType.screenTitle,
        AmpereType.sectionTitle,
        AmpereType.numericHero,
        AmpereType.numeric,
        AmpereType.rowTitle,
        AmpereType.body,
        AmpereType.meta,
        AmpereType.label,
        AmpereType.input,
        AmpereType.h1,
        AmpereType.h2,
        AmpereType.h3,
        AmpereType.h4,
        AmpereType.cardTitle,
        AmpereType.bodyDesktop,
        AmpereType.bodyStrong,
        AmpereType.metaDesktop,
        AmpereType.labelDesktop,
        AmpereType.mono,
      ]) {
        expect(style.fontFamily, AmpereType.family);
      }
    });

    test('les libellés de bouton sont en Archivo, pas en police système', () {
      // Vu à la vérification visuelle : le style de bouton n'hérite pas de
      // ThemeData.fontFamily — sous Windows il serait tombé sur Segoe UI.
      for (final theme in [
        AppTheme.desktop(dark: true),
        AppTheme.mobile(dark: false),
      ]) {
        for (final style in [
          theme.filledButtonTheme.style!,
          theme.outlinedButtonTheme.style!,
          theme.textButtonTheme.style!,
        ]) {
          expect(style.textStyle!.resolve({})!.fontFamily, AmpereType.family);
        }
      }
    });
  });
}
