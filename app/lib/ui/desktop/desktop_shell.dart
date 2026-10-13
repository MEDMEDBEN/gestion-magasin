import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/providers.dart';
import '../../features/auth/data/auth_models.dart';
import '../../features/notifications/application/notifications_controller.dart';
import '../../features/users/data/user_models.dart';
import '../navigation.dart';
import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import '../theme/theme_controller.dart';
import '../widgets/ampere_controls.dart';
import '../widgets/screen_state.dart';
import '../widgets/sync_panel.dart';
import '../../features/assistant/assistant.dart';

/// Menu latéral réduit (rail d'icônes) ou étendu, au choix de l'utilisateur
/// et **gardé par compte** sur le poste, comme le thème. `null` = automatique :
/// rail sous 1180 px de large, menu complet au-delà.
class SidebarCollapsedController extends Notifier<bool?> {
  /// Posé dès que l'utilisateur choisit : une lecture stockée arrivant APRÈS
  /// ne doit pas écraser ce choix (même course que le thème).
  bool _chosen = false;

  static String _key(String userId) => 'sidebar_collapsed.$userId';

  @override
  bool? build() {
    _chosen = false;
    final userId = ref.watch(currentUserIdProvider);
    if (userId != null) _restore(userId);
    return null;
  }

  Future<void> _restore(String userId) async {
    final stored = await ref
        .read(localSettingsStoreProvider)
        .read(_key(userId));
    if (_chosen || !ref.mounted || ref.read(currentUserIdProvider) != userId) {
      return;
    }
    if (stored != null) state = stored == 'true';
  }

  Future<void> set({required bool collapsed}) async {
    _chosen = true;
    state = collapsed;
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    await ref
        .read(localSettingsStoreProvider)
        .write(_key(userId), collapsed ? 'true' : 'false');
  }
}

final sidebarCollapsedProvider =
    NotifierProvider<SidebarCollapsedController, bool?>(
      SidebarCollapsedController.new,
    );

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
    // Le scanner exige une caméra : il ne s'affiche pas au poste.
    final entries = destinationsFor(
      widget.user,
    ).where((d) => !d.mobileOnly).toList();
    final index = _index.clamp(0, entries.length - 1);
    _followRequest(entries);
    final compact = ref.watch(sidebarCollapsedProvider) ?? widget.compact;
    final profile = entries.indexWhere((d) => d.label == 'Mon profil');

    // Ctrl+K ouvre l'assistant depuis n'importe quel écran du poste.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showAssistant(context, ref, widget.user),
      },
      child: Scaffold(
        body: Row(
          children: [
            // Réduit (demande MEDMEDBEN du 2026-10-12) : le menu DISPARAÎT,
            // tout l'écran va au contenu ; une flèche au bord le rouvre.
            if (!compact) ...[
              _Floating(
                child: _Sidebar(
                  user: widget.user,
                  entries: entries,
                  selectedIndex: index,
                  unread: ref.watch(unreadNotificationsProvider).value ?? 0,
                  onSelect: (i) => setState(() => _index = i),
                  onToggle: () => ref
                      .read(sidebarCollapsedProvider.notifier)
                      .set(collapsed: true),
                  onProfile: profile < 0
                      ? null
                      : () => setState(() => _index = profile),
                ),
              ),
              if (Theme.of(context).brightness == Brightness.dark)
                VerticalDivider(width: 1, color: colors.line),
            ],
            Expanded(
              child: Column(
                children: [
                  _TopBar(
                    title: entries[index].label,
                    user: widget.user,
                    // Menu caché : la MÊME double flèche que pour le réduire,
                    // en haut à gauche (demande MEDMEDBEN du 2026-10-13).
                    onExpand: compact
                        ? () => ref
                              .read(sidebarCollapsedProvider.notifier)
                              .set(collapsed: false)
                        : null,
                  ),
                  Divider(height: 1, color: colors.line),
                  Expanded(child: entries[index].builder(context, widget.user)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Suit un raccourci demandé par un écran (accueil, §21). Après la frame :
  /// changer d'onglet PENDANT la construction rejouerait le build en boucle.
  void _followRequest(List<AppDestination> entries) {
    final requested = ref.watch(requestedDestinationProvider);
    if (requested == null) return;
    final target = entries.indexWhere((d) => d.label == requested);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(requestedDestinationProvider.notifier).taken();
      if (target >= 0) setState(() => _index = target);
    });
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.user,
    required this.entries,
    required this.selectedIndex,
    required this.onSelect,
    required this.onToggle,
    this.onProfile,
    this.unread = 0,
  });

  final AuthUser user;
  final List<AppDestination> entries;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// Cache le menu (une poignée au bord le rouvre).
  final VoidCallback onToggle;

  /// Ouvre « Mon profil » depuis le bloc utilisateur du bas.
  final VoidCallback? onProfile;

  /// Notifications non lues. Le nombre est porté par la SIDEBAR, pas par
  /// l'écran : on ne va pas ouvrir une boîte dont rien ne dit qu'elle a du neuf.
  final int unread;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return Container(
      width: 246,
      color: colors.bgAlt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 56,
            // Réduit, l'en-tête ne garde que le bouton pour agrandir : un rail
            // de 64 px n'a la place que d'une icône.
            child: Row(
              children: [
                const SizedBox(width: 18),
                // `zap` est le SEUL éclair du système (§5).
                Icon(LucideIcons.zap, size: 20, color: colors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Gestion magasin',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.h4.copyWith(color: colors.ink),
                  ),
                ),
                IconButton(
                  tooltip: 'Réduire le menu',
                  onPressed: onToggle,
                  icon: Icon(
                    LucideIcons.chevronsLeft,
                    size: 18,
                    color: colors.ink2,
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          Divider(height: 1, color: colors.line),
          // Plus de rubriques que de hauteur (admin, petit écran) : la liste
          // défile, avec un ascenseur visible ; logo et profil restent fixes.
          Expanded(
            child: _NavList(
              children: [
                const SizedBox(height: 10),
                for (var i = 0; i < entries.length; i++)
                  _NavItem(
                    entry: entries[i],
                    selected: i == selectedIndex,
                    unread: entries[i].label == 'Notifications' ? unread : 0,
                    onTap: () => onSelect(i),
                  ),
                const SizedBox(height: 10),
              ],
            ),
          ),
          Divider(height: 1, color: colors.line),
          // Le bloc utilisateur ouvre « Mon profil » (mot de passe, sessions) :
          // c'est là qu'on le cherche d'instinct.
          AmpereTappable(
            onTap: onProfile,
            borderRadius: 0,
            child: _ProfileBlock(user: user),
          ),
        ],
      ),
    );
  }
}

/// Nom et rôles du compte, en bas du menu étendu.
class _ProfileBlock extends StatelessWidget {
  const _ProfileBlock({required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Padding(
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
    );
  }
}

/// Liste des rubriques défilante, ascenseur toujours visible : sans lui, rien
/// ne dit qu'il y a d'autres rubriques plus bas.
class _NavList extends StatefulWidget {
  const _NavList({required this.children});

  final List<Widget> children;

  @override
  State<_NavList> createState() => _NavListState();
}

class _NavListState extends State<_NavList> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _controller,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: widget.children,
        ),
      ),
    );
  }
}

/// Clair (maquette du 2026-10-13) : le menu est une carte blanche flottante,
/// arrondie, posée sur le fond gris. Sombre : collé au bord, comme avant.
class _Floating extends StatelessWidget {
  const _Floating({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).brightness == Brightness.dark) return child;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(borderRadius: BorderRadius.circular(24), child: child),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.entry,
    required this.selected,
    required this.onTap,
    this.unread = 0,
  });

  final AppDestination entry;
  final bool selected;
  final VoidCallback onTap;
  final int unread;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    // Clair : l'actif est une PILULE NOIRE, texte blanc (maquette 2026-10-13).
    final pill = Theme.of(context).brightness == Brightness.light;

    final item = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Semantics(
        selected: selected,
        button: true,
        label: entry.label,
        child: AmpereTappable(
          onTap: onTap,
          borderRadius: AmpereGeometry.fieldRadiusDesktop,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              // Actif : voile d'accent + trait de 2 px à gauche (§6) ; en
              // clair, pilule noire.
              color: selected
                  ? (pill ? colors.accent : colors.accentBg)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(
                pill ? 999 : AmpereGeometry.fieldRadiusDesktop,
              ),
              border: selected && !pill
                  ? Border(left: BorderSide(color: colors.accent, width: 2))
                  : null,
            ),
            child: Row(
              children: [
                Badge.count(
                  count: unread,
                  isLabelVisible: unread > 0,
                  child: Icon(
                    entry.icon,
                    size: 17,
                    color: selected
                        ? (pill ? colors.onAccent : colors.accentHi)
                        : colors.ink2,
                  ),
                ),
                ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.bodyDesktop.copyWith(
                        color: selected
                            ? (pill ? colors.onAccent : colors.ink)
                            : colors.ink2,
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

    return item;
  }
}

/// Barre supérieure fine (44 px, 2026-10-12) : titre, indicateur de sync,
/// bascule de thème — la place va au contenu.
class _TopBar extends ConsumerWidget {
  const _TopBar({required this.title, required this.user, this.onExpand});

  final String title;
  final AuthUser user;

  /// Menu caché : rouvre le menu (`null` quand il est affiché).
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final pending = ref.watch(pendingMutationsCountProvider);
    final rejected = ref.watch(rejectedMutationsProvider);
    final reachable = ref.watch(serverReachableProvider);
    final themeMode = ref.watch(themeModeProvider);

    return Container(
      height: 44,
      color: colors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (onExpand != null) ...[
            IconButton(
              tooltip: 'Agrandir le menu',
              onPressed: onExpand,
              icon: Icon(
                LucideIcons.chevronsRight,
                size: 18,
                color: colors.ink2,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AmpereType.bodyStrong.copyWith(color: colors.ink2),
            ),
          ),
          // Assistant (2026-10-05) : actions préparées, Ctrl+K au clavier.
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Assistant (Ctrl+K)',
            onPressed: () => showAssistant(context, ref, user),
            icon: const Icon(LucideIcons.sparkles, size: 17),
          ),
          const SizedBox(width: 6),
          SyncIndicator(
            pendingCount: pending.value ?? 0,
            rejectedCount: rejected.value?.length ?? 0,
            isOffline: !reachable,
            onTap: () => showSyncPanel(context),
          ),
          const SizedBox(width: 10),
          IconButton(
            visualDensity: VisualDensity.compact,
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
