import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/providers.dart';
import '../../data/models/auth_models.dart';
import '../../features/auth/presentation/profile_screen.dart';
import '../../features/users/presentation/users_screen.dart';
import '../theme/ampere_colors.dart';
import '../widgets/screen_state.dart';

/// Coquille mobile : navigation basse, une action principale par écran, grandes
/// cibles tactiles (spec §29). Ce n'est PAS le desktop en miniature.
///
/// **4 onglets maximum** (AMPÈRE §7) ; les onglets sont filtrés par rôle —
/// la gestion des comptes n'apparaît que pour l'ADMIN, et le backend la
/// refuserait de toute façon aux autres.
class MobileShell extends ConsumerStatefulWidget {
  const MobileShell({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends ConsumerState<MobileShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final pending = ref.watch(pendingMutationsCountProvider);
    final rejected = ref.watch(rejectedMutationsProvider);

    final tabs = _tabsFor(widget.user);
    final index = _index.clamp(0, tabs.length - 1);
    final current = tabs[index];

    return Scaffold(
      appBar: AppBar(
        title: Text(current.label),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              // Badge de synchronisation PERMANENT dans l'en-tête (§7).
              child: SyncIndicator(
                pendingCount: pending.value ?? 0,
                rejectedCount: rejected.value?.length ?? 0,
              ),
            ),
          ),
        ],
      ),
      body: current.builder(context, widget.user),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: colors.surface,
        destinations: [
          for (final tab in tabs)
            NavigationDestination(icon: Icon(tab.icon), label: tab.label),
        ],
      ),
    );
  }

  List<_Tab> _tabsFor(AuthUser user) {
    final home = _Tab(
      icon: LucideIcons.layoutGrid,
      label: 'Accueil',
      builder: (context, user) => ScreenStateView(
        status: ScreenStatus.empty,
        title: 'Bonjour ${user.fullName.split(' ').first}',
        message: 'Les écrans terrain arrivent avec les prochaines features P0.',
      ),
    );

    final profile = _Tab(
      icon: LucideIcons.user,
      label: 'Profil',
      builder: (context, user) => ProfileScreen(user: user),
    );

    if (user.hasRole('ADMIN')) {
      return [
        home,
        _Tab(
          icon: LucideIcons.shield,
          label: 'Utilisateurs',
          builder: (context, _) => const UsersScreen(),
        ),
        profile,
      ];
    }

    return [home, profile];
  }
}

class _Tab {
  const _Tab({required this.icon, required this.label, required this.builder});

  final IconData icon;
  final String label;
  final Widget Function(BuildContext context, AuthUser user) builder;
}
