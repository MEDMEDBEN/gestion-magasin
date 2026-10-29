import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/router/app_router.dart';
import 'ui/breakpoints.dart';
import 'ui/theme/app_theme.dart';
import 'ui/theme/palettes.dart';
import 'ui/widgets/feedback_messenger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppConfig.assertSecureTransport(isRelease: kReleaseMode);
  runApp(const ProviderScope(child: GestionMagasinApp()));
}

class GestionMagasinApp extends ConsumerWidget {
  const GestionMagasinApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Thème SOMBRE par défaut, clair disponible, choix persisté (AMPÈRE §2).
    // Palette au choix (2026-10-28) ; à défaut, Clair / Bleu nuit.
    final palette = currentPalette(ref);
    final dark = palette.dark;

    return MaterialApp.router(
      title: 'Gestion magasin',
      debugShowCheckedModeBanner: false,
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) {
        // La palette AMPÈRE diffère entre desktop et mobile (§2.1-§2.4).
        // Le produit étant un seul code Flutter, on choisit d'après la largeur
        // réelle plutôt que d'après la cible de compilation.
        // Tablette comprise (§9) : elle adopte la coquille ET la palette desktop.
        final isDesktop = isDesktopWidth(MediaQuery.sizeOf(context).width);
        return Theme(
          data: isDesktop
              ? AppTheme.desktop(dark: dark, colors: palette.desktop)
              : AppTheme.mobile(dark: dark, colors: palette.mobile),
          // Les notifications deviennent des effets animés en haut de
          // l'écran (2026-10-29), plus de barre qui monte du bas.
          child: FeedbackMessenger(child: child ?? const SizedBox.shrink()),
        );
      },
      // Thème initial : évite un flash avant que le `builder` n'applique
      // la palette dépendante de la taille.
      theme: AppTheme.mobile(dark: false),
      darkTheme: AppTheme.mobile(dark: true),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    );
  }
}
