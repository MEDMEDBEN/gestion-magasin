import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/providers.dart';
import '../../features/auth/data/auth_models.dart';
import '../../features/notifications/application/notifications_controller.dart';
import '../../features/users/data/user_models.dart';
import '../../features/catalog/presentation/catalog_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../navigation.dart';
import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import '../widgets/glass.dart';
import '../widgets/screen_state.dart';
import '../widgets/section_tabs.dart';
import '../widgets/sync_panel.dart';
import '../../features/assistant/assistant.dart';

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

  /// La page « Plus » est affichée (façon application bancaire, 2026-10-29).
  bool _more = false;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final pending = ref.watch(pendingMutationsCountProvider);
    final rejected = ref.watch(rejectedMutationsProvider);
    final reachable = ref.watch(serverReachableProvider);
    final unread = ref.watch(unreadNotificationsProvider).value ?? 0;

    final tabs = mobileTabOrder(menuFor(widget.user), widget.user);
    final index = _index.clamp(0, tabs.length - 1);
    final current = tabs[index];
    _followRequest(tabs);
    final overflow = tabs.length > _maxTabs;
    // Ouverte depuis « Plus » : une flèche y ramène.
    final fromMore = overflow && index >= _maxTabs - 1;
    final showMore = overflow && _more;
    final moreBadge =
        unread > 0 &&
        tabs.skip(_maxTabs - 1).any((t) => t.label == 'Notifications');

    return Scaffold(
      // En-tête fin (2026-10-12) : la place va au contenu.
      appBar: AppBar(
        toolbarHeight: 48,
        titleTextStyle: AmpereType.h4.copyWith(color: colors.ink),
        leading: fromMore && !showMore
            ? IconButton(
                tooltip: 'Retour',
                icon: const Icon(LucideIcons.chevronLeft),
                onPressed: () => setState(() => _more = true),
              )
            : null,
        title: Text(showMore ? 'Plus' : current.label),
        actions: [
          // Assistant (2026-10-05) : actions préparées, en mots simples.
          IconButton(
            tooltip: 'Assistant',
            onPressed: () => showAssistant(context, ref, widget.user),
            icon: const Icon(LucideIcons.sparkles),
          ),
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
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0.04, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: showMore
            ? _MorePage(
                key: const ValueKey('plus'),
                user: widget.user,
                items: [
                  for (var i = _maxTabs - 1; i < tabs.length; i++) (i, tabs[i]),
                ],
                unread: unread,
                onOpen: (i) => setState(() {
                  _index = i;
                  _more = false;
                }),
              )
            : KeyedSubtree(
                key: ValueKey(current.label),
                child: current.builder(context, widget.user),
              ),
      ),
      // Capsule de verre en bas (2026-10-29) : 4 onglets au plus (§7), le 4ᵉ
      // ouvre la page « Plus » ; à côté, les actions rapides.
      bottomNavigationBar: BottomIsland(
        side: _QuickActions(user: widget.user),
        tabs: [
          for (final (i, tab)
              in (overflow ? tabs.take(_maxTabs - 1) : tabs).indexed)
            IslandTab(
              icon: tab.icon,
              label: tab.label,
              active: !showMore && !fromMore && i == index,
              badge: tab.label == 'Notifications' ? unread : 0,
              onTap: () => setState(() {
                _index = i;
                _more = false;
              }),
            ),
          if (overflow)
            IslandTab(
              icon: LucideIcons.layoutGrid,
              label: 'Plus',
              active: showMore || fromMore,
              badge: moreBadge ? unread : 0,
              onTap: () => setState(() => _more = true),
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
    final target = locate(tabs, requested);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(requestedDestinationProvider.notifier).taken();
      if (target == null) return;
      final tab = tabs[target.index];
      if (tab.sections.isNotEmpty) {
        ref.read(sectionIndexProvider.notifier).set(tab.label, target.section);
      }
      setState(() {
        _index = target.index;
        _more = false;
      });
    });
  }

  static const _maxTabs = 4;
}

/// Onglets du bas SELON LE RÔLE (bug terrain du 2026-10-05 : admin et vendeur
/// voyaient les trois mêmes onglets « Accueil, Vente, Devis », la différence
/// était cachée dans « Plus »). Les destinations préférées du rôle passent en
/// tête ; toutes les autres restent dans « Plus », dans l'ordre du menu.
/// Cumul de rôles : celui de l'admin, puis du vendeur, puis du magasinier.
List<AppDestination> mobileTabOrder(
  List<AppDestination> destinations,
  AuthUser user,
) {
  final preferred = user.hasRole('ADMIN')
      ? const ['Accueil', 'Vente', 'Catalogue']
      : user.hasRole('VENDEUR')
      ? const ['Accueil', 'Vente', 'Scanner']
      : user.hasRole('MAGASINIER')
      ? const ['Accueil', 'Stock', 'Transferts']
      : const <String>[];
  final first = [
    for (final label in preferred)
      ...destinations.where((d) => d.label == label),
  ];
  return [...first, ...destinations.where((d) => !first.contains(d))];
}

/// Groupes de la page « Plus », comme dans une application bancaire : on
/// trouve une fonctionnalité par son THÈME.
const _groups = [
  ('Ventes', ['Vente', 'Devis', 'Catalogue', 'Scanner']),
  (
    'Stock et achats',
    ['Stock', 'Transferts', 'Achats', 'Réappro', 'Inventaire', 'Fournisseurs'],
  ),
  ('Suivi', ['Accueil', 'Rapports', 'Activité', 'Tâches', 'Historique']),
  ('Équipe', ['Messages', 'Notifications', 'Signalements', 'Utilisateurs']),
  ('Compte', ['Paramètres', 'Mon profil']),
];

/// Page « Plus » : la carte du compte, puis les fonctionnalités par thème,
/// en lignes nettes (icône dans un carré arrondi, libellé, aide, flèche).
class _MorePage extends StatelessWidget {
  const _MorePage({
    super.key,
    required this.user,
    required this.items,
    required this.unread,
    required this.onOpen,
  });

  final AuthUser user;
  final List<(int, AppDestination)> items;
  final int unread;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final placed = <String>{};
    final sections = <(String, List<(int, AppDestination)>)>[];
    for (final (title, labels) in _groups) {
      final found = [
        for (final e in items)
          if (labels.contains(e.$2.label)) e,
      ];
      placed.addAll(found.map((e) => e.$2.label));
      if (found.isNotEmpty) sections.add((title, found));
    }
    final rest = [
      for (final e in items)
        if (!placed.contains(e.$2.label)) e,
    ];
    if (rest.isNotEmpty) sections.add(('Autres', rest));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // Carte du compte, en dégradé (comme le solde d'une appli bancaire).
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: colors.accentGradient,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: colors.accent.withValues(alpha: 0.3),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: colors.onAccent.withValues(alpha: 0.18),
                child: Text(
                  user.fullName.isEmpty ? '?' : user.fullName[0].toUpperCase(),
                  style: AmpereType.h4.copyWith(color: colors.onAccent),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.h4.copyWith(color: colors.onAccent),
                    ),
                    Text(
                      formatRoles(user.roles),
                      style: AmpereType.meta.copyWith(
                        color: colors.onAccent.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        for (final (title, entries) in sections) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
            child: Text(
              title.toUpperCase(),
              style: AmpereType.label.copyWith(color: colors.ink3),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colors.line),
            ),
            child: Column(
              children: [
                for (final (k, (i, d)) in entries.indexed) ...[
                  if (k > 0)
                    Divider(height: 1, indent: 60, color: colors.lineSoft),
                  _MoreRow(
                    destination: d,
                    badge: d.label == 'Notifications' ? unread : 0,
                    onTap: () => onOpen(i),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _MoreRow extends StatelessWidget {
  const _MoreRow({
    required this.destination,
    required this.onTap,
    this.badge = 0,
  });

  final AppDestination destination;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final hint = [
      for (final s in destination.sections)
        sectionTabLabels[s.label] ?? s.label,
    ].join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colors.accentBg,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Badge.count(
                count: badge,
                isLabelVisible: badge > 0,
                child: Icon(destination.icon, size: 18, color: colors.accent),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    destination.label,
                    style: AmpereType.bodyStrong.copyWith(
                      color: colors.ink,
                      fontSize: 14,
                    ),
                  ),
                  if (hint.isNotEmpty)
                    Text(
                      hint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.meta.copyWith(color: colors.ink3),
                    ),
                ],
              ),
            ),
            Icon(LucideIcons.chevronRight, size: 17, color: colors.ink3),
          ],
        ),
      ),
    );
  }
}

/// Actions rapides, à portée du pouce (bouton rond à côté de la barre) : les
/// gestes du quotidien, selon les droits du compte.
class _QuickActions extends ConsumerWidget {
  const _QuickActions({required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = menuFor(
      user,
    ).expand((d) => [d.label, ...d.sections.map((s) => s.label)]).toSet();
    final rights = CatalogRights(user);
    final actions = <(IconData, String, VoidCallback)>[
      if (open.contains('Vente'))
        (
          LucideIcons.shoppingCart,
          'Nouvelle vente',
          () => goToDestination(ref, 'Vente'),
        ),
      if (open.contains('Scanner'))
        (
          LucideIcons.scanBarcode,
          'Scanner',
          () => goToDestination(ref, 'Scanner'),
        ),
      if (rights.canWriteProducts)
        (
          LucideIcons.packagePlus,
          'Ajout rapide produit',
          () => quickAddProduct(context, ref, rights),
        ),
      if (open.contains('Transferts'))
        (
          LucideIcons.arrowLeftRight,
          'Transferts',
          () => goToDestination(ref, 'Transferts'),
        ),
    ];
    if (actions.isEmpty) return const SizedBox.shrink();
    final colors = AmpereColors.of(context);
    return MenuAnchor(
      alignmentOffset: const Offset(-150, -8),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surface),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: colors.line),
          ),
        ),
      ),
      menuChildren: [
        for (final (icon, label, onTap) in actions)
          MenuItemButton(
            leadingIcon: Icon(icon, size: 18),
            onPressed: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(label),
            ),
          ),
      ],
      builder: (context, controller, _) => GlassRoundButton(
        icon: LucideIcons.zap,
        tooltip: 'Actions rapides',
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
