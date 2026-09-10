import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/providers.dart';
import '../../data/models/auth_models.dart';
import '../../data/models/user_models.dart';
import '../../features/auth/presentation/profile_screen.dart';
import '../../features/users/presentation/users_screen.dart';
import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import '../theme/theme_controller.dart';
import '../widgets/screen_state.dart';

/// Coquille desktop : sidebar fixe 246 px, barre supérieure 56 px,
/// densité assumée (AMPÈRE §6 et §9).
class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final entries = _entriesFor(widget.user);
    final index = _index.clamp(0, entries.length - 1);

    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            user: widget.user,
            entries: entries,
            selectedIndex: index,
            onSelect: (i) => setState(() => _index = i),
          ),
          VerticalDivider(width: 1, color: colors.line),
          Expanded(
            child: Column(
              children: [
                _TopBar(title: entries[index].label),
                Divider(height: 1, color: colors.line),
                Expanded(child: entries[index].builder(context, widget.user)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Le menu est dérivé du rôle : une entrée que le backend refuserait
  /// n'a pas à être proposée (§6).
  List<_NavEntry> _entriesFor(AuthUser user) {
    final entries = <_NavEntry>[
      _NavEntry(
        icon: LucideIcons.layoutGrid,
        label: 'Tableau de bord',
        builder: (context, user) => ScreenStateView(
          status: ScreenStatus.empty,
          title: 'Bonjour ${user.fullName.split(' ').first}',
          message: 'Les modules arrivent avec les prochaines features P0. '
              'La fondation (session, synchronisation, thème) est en place.',
        ),
      ),
    ];

    if (user.hasRole('ADMIN')) {
      entries.add(
        _NavEntry(
          icon: LucideIcons.shield,
          label: 'Utilisateurs',
          builder: (context, _) => const UsersScreen(),
        ),
      );
    }

    entries.add(
      _NavEntry(
        icon: LucideIcons.user,
        label: 'Mon profil',
        builder: (context, user) => ProfileScreen(user: user),
      ),
    );
    return entries;
  }
}

class _NavEntry {
  const _NavEntry({
    required this.icon,
    required this.label,
    required this.builder,
  });

  final IconData icon;
  final String label;
  final Widget Function(BuildContext context, AuthUser user) builder;
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.user,
    required this.entries,
    required this.selectedIndex,
    required this.onSelect,
  });

  final AuthUser user;
  final List<_NavEntry> entries;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return Container(
      width: 246,
      color: colors.bgAlt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                // `zap` est le SEUL éclair du système (§5).
                Icon(LucideIcons.zap, size: 20, color: colors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Gestion magasin',
                    style: AmpereType.h4.copyWith(color: colors.ink),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.line),
          const SizedBox(height: 10),
          for (var i = 0; i < entries.length; i++)
            _NavItem(
              entry: entries[i],
              selected: i == selectedIndex,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          Divider(height: 1, color: colors.line),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  formatRoles(user.roles),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AmpereType.metaDesktop.copyWith(color: colors.ink3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final _NavEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AmpereGeometry.fieldRadiusDesktop),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AmpereGeometry.fieldRadiusDesktop),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              // Actif : voile d'accent + trait de 2 px à gauche (§6).
              color: selected ? colors.accentBg : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(AmpereGeometry.fieldRadiusDesktop),
              border: selected
                  ? Border(left: BorderSide(color: colors.accent, width: 2))
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  entry.icon,
                  size: 17,
                  color: selected ? colors.accentHi : colors.ink2,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.bodyDesktop.copyWith(
                      color: selected ? colors.ink : colors.ink2,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Barre supérieure 56 px (§6) : titre, indicateur de sync, bascule de thème.
class _TopBar extends ConsumerWidget {
  const _TopBar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final pending = ref.watch(pendingMutationsCountProvider);
    final rejected = ref.watch(rejectedMutationsProvider);
    final themeMode = ref.watch(themeModeProvider);

    return Container(
      height: 56,
      color: colors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Text(title, style: AmpereType.h4.copyWith(color: colors.ink)),
          const Spacer(),
          SyncIndicator(
            pendingCount: pending.value ?? 0,
            rejectedCount: rejected.value?.length ?? 0,
          ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: themeMode == ThemeMode.dark ? 'Thème clair' : 'Thème sombre',
            onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
            icon: Icon(
              themeMode == ThemeMode.dark ? LucideIcons.sun : LucideIcons.moon,
              size: 17,
            ),
          ),
        ],
      ),
    );
  }
}
