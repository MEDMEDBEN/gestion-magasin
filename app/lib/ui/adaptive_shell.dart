import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/application/auth_controller.dart';
import 'desktop/desktop_shell.dart';
import 'mobile/mobile_shell.dart';
import 'widgets/screen_state.dart';

/// Seuil de bascule desktop / mobile.
/// Le mobile n'est PAS une copie miniature du desktop (spec §29) : les deux
/// shells sont des mises en page distinctes, sur une logique métier commune.
const double kDesktopBreakpoint = 900;

class AdaptiveShell extends ConsumerWidget {
  const AdaptiveShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);

    if (auth.isLoading) {
      return const Scaffold(
        body: ScreenStateView(status: ScreenStatus.loading),
      );
    }

    return switch (auth.value) {
      AuthSignedIn(:final user) => LayoutBuilder(
          builder: (context, constraints) =>
              constraints.maxWidth >= kDesktopBreakpoint
                  ? DesktopShell(user: user)
                  : MobileShell(user: user),
        ),
      // Session non résolue : serveur injoignable ou en panne au lancement.
      // On NE déconnecte pas — l'offline-first est le cœur du produit — mais on
      // ne laisse surtout pas l'utilisateur bloqué sur un spinner sans issue :
      // il doit pouvoir relancer la tentative dès que le réseau revient.
      _ => Scaffold(
          body: ScreenStateView(
            status: ScreenStatus.offline,
            message: 'Serveur injoignable.\n'
                'Vos opérations en attente sont conservées et seront '
                'synchronisées au retour de la connexion.',
            onRetry: () => ref.invalidate(authControllerProvider),
          ),
        ),
    };
  }
}
