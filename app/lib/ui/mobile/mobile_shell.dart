import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../features/auth/data/auth_models.dart';
import '../navigation.dart';
import '../theme/ampere_colors.dart';
import '../widgets/screen_state.dart';

/// Coquille mobile : navigation basse, une action principale par écran, grandes
/// cibles tactiles (spec §29). Ce n'est PAS le desktop en miniature.
///
/// **4 onglets maximum** (AMPÈRE §7), filtrés par droits (`destinationsFor`).
/// L'en-tête est porté par la coquille — les écrans hébergés n'ont pas le leur
/// (revue C10) — avec le badge de synchronisation PERMANENT (§7).
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
    final reachable = ref.watch(serverReachableProvider);

    final tabs = destinationsFor(widget.user);
    final index = _index.clamp(0, tabs.length - 1);
    final current = tabs[index];

    return Scaffold(
      appBar: AppBar(
        title: Text(current.label),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: SyncIndicator(
                pendingCount: pending.value ?? 0,
                rejectedCount: rejected.value?.length ?? 0,
                isOffline: !reachable,
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
}
