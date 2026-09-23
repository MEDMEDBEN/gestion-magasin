import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/providers.dart';
import '../../features/auth/data/auth_models.dart';
import '../../features/notifications/application/notifications_controller.dart';
import '../navigation.dart';
import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import '../widgets/screen_state.dart';
import '../widgets/sync_panel.dart';

/// Coquille mobile : navigation basse, une action principale par écran, grandes
/// cibles tactiles (spec §29). Ce n'est PAS le desktop en miniature.
///
/// **4 onglets maximum** (AMPÈRE §7), filtrés par droits (`destinationsFor`) ;
/// au-delà, le 4ᵉ devient « Plus » et liste les destinations restantes.
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
    final unread = ref.watch(unreadNotificationsProvider).value ?? 0;

    final tabs = destinationsFor(widget.user);
    final index = _index.clamp(0, tabs.length - 1);
    final current = tabs[index];
    _followRequest(tabs);
    final overflow = tabs.length > _maxTabs;

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
                onTap: () => showSyncPanel(context),
              ),
            ),
          ),
        ],
      ),
      body: current.builder(context, widget.user),
      bottomNavigationBar: NavigationBar(
        // Au-delà de 4 destinations (§7), les suivantes passent dans « Plus ».
        selectedIndex: overflow ? index.clamp(0, _maxTabs - 1) : index,
        onDestinationSelected: (i) {
          if (overflow && i == _maxTabs - 1) {
            _openMore(tabs);
          } else {
            setState(() => _index = i);
          }
        },
        backgroundColor: colors.surface,
        destinations: [
          for (final tab in overflow ? tabs.take(_maxTabs - 1) : tabs)
            NavigationDestination(
              icon: Badge.count(
                // Non lues : seul l'onglet Notifications porte le compteur ;
                // sans lui, personne n'irait voir une boîte muette.
                count: unread,
                isLabelVisible: tab.label == 'Notifications' && unread > 0,
                child: Icon(tab.icon),
              ),
              label: tab.label,
            ),
          if (overflow)
            NavigationDestination(
              // « Plus » hérite du compteur des onglets qu'il cache : sinon,
              // sur un téléphone où Notifications passe dessous, rien ne
              // signalerait jamais une alerte.
              icon: Badge.count(
                count: unread,
                isLabelVisible:
                    unread > 0 &&
                    tabs
                        .skip(_maxTabs - 1)
                        .any((t) => t.label == 'Notifications'),
                child: const Icon(LucideIcons.ellipsis),
              ),
              label: 'Plus',
            ),
        ],
      ),
    );
  }

  /// Suit un raccourci demandé par un écran (accueil, §21) — après la frame,
  /// pour ne pas relancer la construction en cours.
  void _followRequest(List<AppDestination> tabs) {
    final requested = ref.watch(requestedDestinationProvider);
    if (requested == null) return;
    final target = tabs.indexWhere((d) => d.label == requested);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(requestedDestinationProvider.notifier).taken();
      if (target >= 0) setState(() => _index = target);
    });
  }

  static const _maxTabs = 4;

  /// Liste des destinations qui ne tiennent pas dans la barre.
  Future<void> _openMore(List<AppDestination> tabs) async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      // DÉFILANTE : un admin a désormais plus d'entrées qu'un petit écran n'en
      // montre. Une colonne fixe laissait les dernières HORS de l'écran,
      // inaccessibles sur téléphone.
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = _maxTabs - 1; i < tabs.length; i++)
                ListTile(
                  minTileHeight: AmpereGeometry.listRowMin,
                  leading: Icon(tabs[i].icon),
                  title: Text(tabs[i].label),
                  selected: i == _index,
                  onTap: () => Navigator.of(context).pop(i),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) setState(() => _index = chosen);
  }
}
