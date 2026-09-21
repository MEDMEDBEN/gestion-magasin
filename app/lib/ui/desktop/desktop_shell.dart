import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/providers.dart';
import '../../features/auth/data/auth_models.dart';
import '../../features/users/data/user_models.dart';
import '../navigation.dart';
import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import '../theme/theme_controller.dart';
import '../widgets/ampere_controls.dart';
import '../widgets/screen_state.dart';
import '../widgets/sync_panel.dart';

/// Coquille desktop : sidebar fixe 246 px (ou rail d'icônes 64 px sur
/// tablette, §9), barre supérieure 56 px, densité assumée (AMPÈRE §6 et §9).
class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key, required this.user, this.compact = false});

  final AuthUser user;

  /// Tablette (768-1180 px) : la sidebar se réduit à un rail d'icônes.
  final bool compact;

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final entries = destinationsFor(widget.user);
    final index = _index.clamp(0, entries.length - 1);

    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            user: widget.user,
            entries: entries,
            selectedIndex: index,
            compact: widget.compact,
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
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.user,
    required this.entries,
    required this.selectedIndex,
    required this.compact,
    required this.onSelect,
  });

  final AuthUser user;
  final List<AppDestination> entries;
  final int selectedIndex;
  final bool compact;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return Container(
      width: compact ? 64 : 246,
      color: colors.bgAlt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 56,
            child: Row(
              mainAxisAlignment: compact
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                if (!compact) const SizedBox(width: 18),
                // `zap` est le SEUL éclair du système (§5).
                Icon(LucideIcons.zap, size: 20, color: colors.accent),
                if (!compact) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Gestion magasin',
                      style: AmpereType.h4.copyWith(color: colors.ink),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: colors.line),
          const SizedBox(height: 10),
          for (var i = 0; i < entries.length; i++)
            _NavItem(
              entry: entries[i],
              selected: i == selectedIndex,
              compact: compact,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          Divider(height: 1, color: colors.line),
          if (compact)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Tooltip(
                message: '${user.fullName} — ${formatRoles(user.roles)}',
                child: const Center(
                  child: AmpereIconChip(icon: LucideIcons.user, size: 34),
                ),
              ),
            )
          else
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
    required this.compact,
    required this.onTap,
  });

  final AppDestination entry;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    final item = Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: 2),
      child: Semantics(
        selected: selected,
        button: true,
        label: entry.label,
        child: AmpereTappable(
          onTap: onTap,
          borderRadius: AmpereGeometry.fieldRadiusDesktop,
          child: Container(
            height: 36,
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 10),
            decoration: BoxDecoration(
              // Actif : voile d'accent + trait de 2 px à gauche (§6).
              color: selected ? colors.accentBg : Colors.transparent,
              borderRadius: BorderRadius.circular(
                AmpereGeometry.fieldRadiusDesktop,
              ),
              border: selected
                  ? Border(left: BorderSide(color: colors.accent, width: 2))
                  : null,
            ),
            child: Row(
              mainAxisAlignment: compact
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Icon(
                  entry.icon,
                  size: 17,
                  color: selected ? colors.accentHi : colors.ink2,
                ),
                if (!compact) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.bodyDesktop.copyWith(
                        color: selected ? colors.ink : colors.ink2,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    // En rail, le libellé reste accessible au survol et aux lecteurs d'écran.
    return compact ? Tooltip(message: entry.label, child: item) : item;
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
    final reachable = ref.watch(serverReachableProvider);
    final themeMode = ref.watch(themeModeProvider);

    return Container(
      height: 56,
      color: colors.bg,
      padding: const EdgeInsets.symmetric(
        horizontal: AmpereGeometry.screenMarginDesktop,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AmpereType.h4.copyWith(color: colors.ink),
            ),
          ),
          SyncIndicator(
            pendingCount: pending.value ?? 0,
            rejectedCount: rejected.value?.length ?? 0,
            isOffline: !reachable,
            onTap: () => showSyncPanel(context),
          ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: themeMode == ThemeMode.dark
                ? 'Thème clair'
                : 'Thème sombre',
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
