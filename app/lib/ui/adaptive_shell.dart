import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/application/auth_controller.dart';
import 'breakpoints.dart';
import 'desktop/desktop_shell.dart';
import 'mobile/mobile_shell.dart';
import 'widgets/screen_state.dart';

/// Choisit la coquille selon la largeur (AMPÈRE §9) : mobile sous 768 px,
/// desktop au-delà — en rail d'icônes jusqu'à 1180 px (tablette).
class AdaptiveShell extends ConsumerWidget {
  const AdaptiveShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);

    // Chargement plein écran UNIQUEMENT tant qu'aucune session n'est connue
    // (démarrage). Un rechargement ultérieur ne démonte pas la coquille : sinon
    // l'utilisateur perdrait sa navigation au moindre appel (revue C9).
    if (!auth.hasValue) {
      return const Scaffold(
        body: ScreenStateView(status: ScreenStatus.loading),
      );
    }

    return switch (auth.value) {
      AuthSignedIn(:final user) => LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          if (!isDesktopWidth(width)) return MobileShell(user: user);
          return DesktopShell(user: user, compact: width < kDesktopMinWidth);
        },
      ),
      // Session non résolue : serveur injoignable ou en panne au lancement.
      // On NE déconnecte pas — l'offline-first est le cœur du produit — mais on
      // ne laisse surtout pas l'utilisateur bloqué sur un spinner sans issue :
      // il doit pouvoir relancer la tentative dès que le réseau revient.
      _ => Scaffold(
        body: ScreenStateView(
          status: ScreenStatus.offline,
          message:
              'Serveur injoignable.\n'
              'Vos opérations en attente sont conservées et seront '
              'synchronisées au retour de la connexion.',
          onRetry: () => ref.invalidate(authControllerProvider),
        ),
      ),
    };
  }
}
