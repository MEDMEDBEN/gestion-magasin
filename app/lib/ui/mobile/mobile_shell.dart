import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/auth_models.dart';
import '../../features/auth/application/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/screen_state.dart';

/// Coquille mobile : navigation basse, une action principale par écran,
/// grandes cibles tactiles (spec §29). Ce n'est PAS le desktop en miniature.
///
/// Les onglets sont filtrés par rôle : chaque membre ne voit que son terrain.
class MobileShell extends ConsumerWidget {
  const MobileShell({super.key, required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingMutationsCountProvider);
    final rejected = ref.watch(rejectedMutationsProvider);
    final destinations = _destinationsFor(user);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestion magasin'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: SyncIndicator(
                pendingCount: pending.value ?? 0,
                rejectedCount: rejected.value?.length ?? 0,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ScreenStateView(
              status: ScreenStatus.empty,
              message: 'Bonjour ${user.fullName}.\n'
                  'Les écrans terrain arrivent avec les features P0.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextButton.icon(
              onPressed: () =>
                  ref.read(authControllerProvider.notifier).logout(),
              icon: const Icon(Icons.logout, size: 16),
              label: const Text('Déconnexion'),
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: AppColors.surface,
        destinations: destinations,
      ),
    );
  }

  /// Navigation adaptée au rôle — le vendeur vend, le magasinier prépare.
  static List<NavigationDestination> _destinationsFor(AuthUser user) {
    const home = NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: 'Accueil',
    );
    const tasks = NavigationDestination(
      icon: Icon(Icons.checklist_outlined),
      label: 'Tâches',
    );
    const more = NavigationDestination(
      icon: Icon(Icons.more_horiz),
      label: 'Plus',
    );

    if (user.hasRole('MAGASINIER')) {
      return const [
        home,
        NavigationDestination(
          icon: Icon(Icons.qr_code_scanner),
          label: 'Scanner',
        ),
        NavigationDestination(
          icon: Icon(Icons.inventory_2_outlined),
          label: 'Stock',
        ),
        tasks,
        more,
      ];
    }

    if (user.hasRole('VENDEUR')) {
      return const [
        home,
        NavigationDestination(
          icon: Icon(Icons.point_of_sale_outlined),
          label: 'Ventes',
        ),
        NavigationDestination(
          icon: Icon(Icons.inventory_2_outlined),
          label: 'Stock',
        ),
        tasks,
        more,
      ];
    }

    return const [home, tasks, more];
  }
}
