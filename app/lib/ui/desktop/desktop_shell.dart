import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../features/auth/data/auth_models.dart';
import '../../features/home/application/dashboard_controller.dart';
import '../../features/messaging/application/conversations_controller.dart';
import '../../features/notifications/application/notifications_controller.dart';
import '../../features/users/data/user_models.dart';
import '../navigation.dart';
import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import '../theme/theme_controller.dart';
import '../widgets/screen_state.dart';
import '../widgets/signal_background.dart';
import '../widgets/sync_panel.dart';
import '../../features/assistant/assistant.dart';

/// Coquille du poste (demande MEDMEDBEN du 2026-10-28) : PAS de menu latéral.
/// À la connexion, un ÉCRAN D'ACCUEIL présente le compte et toutes les
/// fonctionnalités en grandes tuiles (tableau de bord et vente en avant) ;
/// dans une fonctionnalité, la barre du haut porte un bouton « Accueil » qui
/// ramène aux tuiles. Les destinations et leurs droits restent ceux de
/// [destinationsFor] : seule la façon d'y aller change.
class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key, required this.user, this.compact = false});

  final AuthUser user;

  /// Écran moyen (768-1180 px) : tuiles sur deux colonnes.
  final bool compact;

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

/// Libellé affiché pour une destination : l'ancien « Accueil » (les chiffres
/// du jour) est le TABLEAU DE BORD ; « Accueil » désigne désormais les tuiles.
String _display(String label) => label == 'Accueil' ? 'Tableau de bord' : label;

class _DesktopShellState extends ConsumerState<DesktopShell> {
  /// Destination ouverte ; `null` = l'écran d'accueil (les tuiles).
  int? _index;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    // Le scanner exige une caméra : il ne s'affiche pas au poste.
    final entries = destinationsFor(
      widget.user,
    ).where((d) => !d.mobileOnly).toList();
    final index = _index?.clamp(0, entries.length - 1);
    _followRequest(entries);
    void open(int? i) => setState(() => _index = i);

    // Ctrl+K : l'assistant ; Échap : retour à l'accueil.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showAssistant(context, ref, widget.user),
        if (index != null)
          const SingleActivator(LogicalKeyboardKey.home, alt: true): () =>
              open(null),
      },
      child: Scaffold(
        body: Stack(
          children: [
            // Fond « signal électrique », éteignable (2026-10-28).
            if (ref.watch(signalBackgroundProvider))
              const Positioned.fill(child: SignalBackground()),
            Column(
              children: [
                _TopBar(
                  title: index == null
                      ? 'Accueil'
                      : _display(entries[index].label),
                  user: widget.user,
                  onHome: index == null ? null : () => open(null),
                ),
                Divider(height: 1, color: colors.line),
                Expanded(
                  // Passage fluide entre l'accueil et une fonctionnalité.
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.015),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: index == null
                        ? _Launcher(
                            key: const ValueKey('accueil'),
                            user: widget.user,
                            entries: entries,
                            columns: widget.compact ? 2 : 3,
                            unread:
                                ref.watch(unreadNotificationsProvider).value ??
                                0,
                            onOpen: open,
                          )
                        : KeyedSubtree(
                            key: ValueKey(entries[index].label),
                            child: entries[index].builder(context, widget.user),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Suit un raccourci demandé par un écran (tableau de bord, assistant).
  /// Après la frame : changer d'écran PENDANT la construction rejouerait le
  /// build en boucle.
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

/// Ce que fait chaque fonctionnalité, en une ligne, sous sa tuile.
const _hints = {
  'Accueil': 'Les chiffres du jour et ce qui demande une action',
  'Vente': 'Encaisser, tickets, clients',
  'Devis': 'Préparer et suivre les devis',
  'Catalogue': 'Produits, prix, catégories',
  'Stock': 'Niveaux au magasin et au dépôt',
  'Tâches': 'Le planning de l’équipe',
  'Transferts': 'Entre le dépôt et le magasin',
  'Achats': 'Commandes et réceptions fournisseurs',
  'Activité': 'Ce qui s’est passé, au fil de l’eau',
  'Rapports': 'Ventes, marges, produits',
  'Réappro': 'Ce qu’il faut racheter',
  'Inventaire': 'Compter et corriger le stock',
  'Fournisseurs': 'Fiches, dettes, paiements',
  'Utilisateurs': 'Comptes et rôles de l’équipe',
  'Paramètres': 'Magasin, impression, réglages',
  'Historique': 'Journal des opérations',
  'Signalements': 'Problèmes remontés par l’équipe',
  'Messages': 'Discuter avec l’équipe',
  'Notifications': 'Alertes et rappels',
  'Mon profil': 'Mot de passe, sessions, thème',
};

/// L'essentiel d'un logiciel de vente, en tête et en grand.
const _essentials = [
  'Accueil',
  'Vente',
  'Stock',
  'Catalogue',
  'Transferts',
  'Achats',
];

/// L'écran d'accueil : le compte, puis les fonctionnalités en tuiles.
class _Launcher extends ConsumerWidget {
  const _Launcher({
    super.key,
    required this.user,
    required this.entries,
    required this.columns,
    required this.unread,
    required this.onOpen,
  });

  final AuthUser user;
  final List<AppDestination> entries;
  final int columns;
  final int unread;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final indexed = [for (final (i, d) in entries.indexed) (i, d)];
    final main = [
      for (final label in _essentials)
        ...indexed.where((e) => e.$2.label == label),
    ];
    final others = [
      for (final e in indexed)
        if (!_essentials.contains(e.$2.label)) e,
    ];
    final profile = entries.indexWhere((d) => d.label == 'Mon profil');

    Widget tile((int, AppDestination) e, {required bool big}) => _Tile(
      icon: e.$2.label == 'Accueil' ? LucideIcons.layoutDashboard : e.$2.icon,
      title: _display(e.$2.label),
      hint: _hints[e.$2.label] ?? '',
      big: big,
      // Tableau de bord et Vente : mis en avant (demande du 2026-10-28).
      prominent: e.$2.label == 'Accueil' || e.$2.label == 'Vente',
      badge: e.$2.label == 'Notifications' ? unread : 0,
      onTap: () => onOpen(e.$1),
    );

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 40),
          children: [
            // Le compte : qui est connecté ; toucher ouvre « Mon profil ».
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: profile < 0 ? null : () => onOpen(profile),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: colors.accent,
                      child: Text(
                        _initials(user.fullName),
                        style: AmpereType.h4.copyWith(color: colors.onAccent),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Bonjour ${user.fullName.split(' ').first}',
                            style: AmpereType.h1.copyWith(color: colors.ink),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${user.fullName} · ${formatRoles(user.roles)} · '
                            '${formatDate(DateTime.now())}',
                            style: AmpereType.bodyDesktop.copyWith(
                              color: colors.ink3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),
            _Today(
              columns: columns == 2 ? 3 : 6,
              open: (label) {
                final i = entries.indexWhere((d) => d.label == label);
                if (i >= 0) onOpen(i);
              },
            ),
            const SizedBox(height: 28),
            _SectionLabel('L’essentiel'),
            const SizedBox(height: 12),
            _Grid(
              columns: columns,
              children: [for (final e in main) tile(e, big: true)],
            ),
            if (others.isNotEmpty) ...[
              const SizedBox(height: 32),
              _SectionLabel('Toutes les fonctionnalités'),
              const SizedBox(height: 12),
              _Grid(
                columns: columns,
                children: [for (final e in others) tile(e, big: false)],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: AmpereType.label.copyWith(color: AmpereColors.of(context).ink3),
  );
}

/// Grille à colonnes égales, aérée.
class _Grid extends StatelessWidget {
  const _Grid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  static const _gap = 16.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final width = (box.maxWidth - _gap * (columns - 1)) / columns;
      return Wrap(
        spacing: _gap,
        runSpacing: _gap,
        children: [for (final c in children) SizedBox(width: width, child: c)],
      );
    },
  );
}

/// Une fonctionnalité en tuile : grande (l'essentiel) ou moyenne (le reste).
/// Mise en avant : pleine (noir en clair, blanc en sombre).
class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.hint,
    required this.big,
    required this.prominent,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String title;
  final String hint;
  final bool big;
  final bool prominent;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final ink = prominent ? colors.onAccent : colors.ink;
    final soft = prominent
        ? colors.onAccent.withValues(alpha: 0.7)
        : colors.ink3;
    final iconBox = Container(
      width: big ? 44 : 36,
      height: big ? 44 : 36,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: prominent ? colors.onAccent.withValues(alpha: 0.12) : null,
        border: Border.all(
          color: prominent
              ? colors.onAccent.withValues(alpha: 0.2)
              : colors.line,
        ),
      ),
      child: Badge.count(
        count: badge,
        isLabelVisible: badge > 0,
        child: Icon(icon, size: big ? 22 : 18, color: ink),
      ),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: (big ? AmpereType.h3 : AmpereType.rowTitle).copyWith(
            color: ink,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          hint,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AmpereType.meta.copyWith(color: soft),
        ),
      ],
    );
    return Semantics(
      button: true,
      label: title,
      child: Material(
        color: prominent ? colors.accent : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: prominent ? colors.accent : colors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(big ? 20 : 14),
            child: big
                ? SizedBox(
                    height: 118,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            iconBox,
                            const Spacer(),
                            Icon(
                              LucideIcons.arrowUpRight,
                              size: 18,
                              color: soft,
                            ),
                          ],
                        ),
                        const Spacer(),
                        text,
                      ],
                    ),
                  )
                : Row(
                    children: [
                      iconBox,
                      const SizedBox(width: 12),
                      Expanded(child: text),
                      Icon(LucideIcons.chevronRight, size: 16, color: soft),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Barre du haut : à l'accueil, le nom du logiciel ; dans une fonctionnalité,
/// le bouton « Accueil » (toujours à gauche) puis le titre. À droite :
/// assistant, synchronisation, thème.
class _TopBar extends ConsumerWidget {
  const _TopBar({required this.title, required this.user, this.onHome});

  final String title;
  final AuthUser user;

  /// Retour aux tuiles ; `null` quand on y est déjà.
  final VoidCallback? onHome;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final pending = ref.watch(pendingMutationsCountProvider);
    final rejected = ref.watch(rejectedMutationsProvider);
    final reachable = ref.watch(serverReachableProvider);
    final themeMode = ref.watch(themeModeProvider);
    final home = onHome;

    return Container(
      height: 56,
      color: colors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (home == null) ...[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: colors.accent,
                borderRadius: BorderRadius.circular(8),
              ),
              // `zap` est le SEUL éclair du système (§5).
              child: Icon(LucideIcons.zap, size: 16, color: colors.onAccent),
            ),
            const SizedBox(width: 10),
            Text(
              'Gestion magasin',
              style: AmpereType.h4.copyWith(color: colors.ink),
            ),
          ] else ...[
            Tooltip(
              message: 'Retour à l’accueil (Alt+Origine)',
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                onPressed: home,
                icon: const Icon(LucideIcons.house, size: 16),
                label: const Text('Accueil'),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AmpereType.h4.copyWith(color: colors.ink),
              ),
            ),
          ],
          if (home == null) const Spacer(),
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
          const SizedBox(width: 6),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: ref.watch(signalBackgroundProvider)
                ? 'Éteindre le fond animé'
                : 'Allumer le fond animé',
            onPressed: () =>
                ref.read(signalBackgroundProvider.notifier).toggle(),
            icon: Icon(
              LucideIcons.activity,
              size: 17,
              color: ref.watch(signalBackgroundProvider)
                  ? colors.accent
                  : colors.ink3,
            ),
          ),
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

/// « Aujourd'hui » (demande MEDMEDBEN du 2026-10-28) : l'essentiel à savoir
/// AVANT d'ouvrir une fonctionnalité — caisse, messages, tâches, alerte, plus
/// les ventes du jour et ce qui arrive (transferts, livraisons). Une ligne de
/// petites cartes, chacune cliquable vers l'écran où agir. Un bloc que le
/// serveur n'envoie pas (droits) n'est pas affiché ; rien à montrer : rien.
class _Today extends ConsumerWidget {
  const _Today({required this.columns, required this.open});

  final int columns;
  final ValueChanged<String> open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(dashboardSummaryProvider).value;
    final conversations = ref.watch(conversationsProvider(false)).value;
    final unreadMessages = conversations?.data.fold<int>(
      0,
      (sum, c) => sum + c.unread,
    );

    final cash = summary?.cash;
    final tasks = summary?.tasks;
    final stock = summary?.stock;
    final customers = summary?.customers;
    final sales = summary?.sales;
    final transfers = summary?.transfers;
    final purchases = summary?.purchases;

    // L'alerte la plus grave du moment, une seule.
    final alert = stock != null && stock.outOfStockCount > 0
        ? (StatusTone.error, '${stock.outOfStockCount} en rupture', 'Stock')
        : customers != null && customers.overdue > 0
        ? (StatusTone.error, 'Créances ${formatDA(customers.overdue)}', 'Vente')
        : stock != null && stock.lowCount > 0
        ? (StatusTone.warn, '${stock.lowCount} sous le seuil', 'Stock')
        : (stock != null || customers != null)
        ? (StatusTone.ok, 'Aucune alerte', 'Stock')
        : null;

    final items = <_TodayItem>[
      if (cash != null)
        _TodayItem(
          icon: cash.open ? LucideIcons.wallet : LucideIcons.lock,
          label: 'Caisse',
          value: cash.open ? formatDA(cash.currentAmount) : 'Fermée',
          tone: cash.open ? StatusTone.ok : StatusTone.warn,
          target: 'Vente',
        ),
      if (unreadMessages != null)
        _TodayItem(
          icon: LucideIcons.messagesSquare,
          label: 'Messages',
          value: unreadMessages == 0
              ? 'Rien de nouveau'
              : '$unreadMessages non lu${unreadMessages > 1 ? 's' : ''}',
          tone: unreadMessages == 0 ? StatusTone.neutral : StatusTone.info,
          target: 'Messages',
        ),
      if (tasks != null)
        _TodayItem(
          icon: LucideIcons.listChecks,
          label: 'Tâches',
          value: tasks.late > 0
              ? '${tasks.open} à faire · ${tasks.late} en retard'
              : '${tasks.open} à faire',
          tone: tasks.late > 0
              ? StatusTone.error
              : tasks.open > 0
              ? StatusTone.info
              : StatusTone.ok,
          target: 'Tâches',
        ),
      if (alert case (final tone, final text, final target))
        _TodayItem(
          icon: LucideIcons.triangleAlert,
          label: 'Alerte',
          value: text,
          tone: tone,
          target: target,
        ),
      if (sales != null)
        _TodayItem(
          icon: LucideIcons.banknote,
          label: 'Ventes du jour',
          value:
              '${formatDA(sales.revenueTtc)} · ${sales.count} vente${sales.count > 1 ? 's' : ''}',
          tone: StatusTone.neutral,
          target: 'Accueil',
        ),
      if (transfers != null || purchases != null)
        _TodayItem(
          icon: LucideIcons.truck,
          label: 'À traiter',
          value: [
            if (transfers != null) '${transfers.toPrepare} transfert(s)',
            if (purchases != null) '${purchases.toReceive} livraison(s)',
          ].join(' · '),
          tone: (transfers?.toPrepare ?? 0) + (purchases?.toReceive ?? 0) > 0
              ? StatusTone.info
              : StatusTone.neutral,
          target: transfers != null ? 'Transferts' : 'Achats',
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('Aujourd’hui'),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) {
            const gap = 10.0;
            final perRow = columns.clamp(1, items.length);
            final width = (box.maxWidth - gap * (perRow - 1)) / perRow;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final item in items)
                  SizedBox(
                    width: width,
                    child: _TodayCard(item: item, onTap: open),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _TodayItem {
  const _TodayItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
    required this.target,
  });

  final IconData icon;
  final String label;
  final String value;
  final StatusTone tone;

  /// Destination ouverte au clic (libellé de [destinationsFor]).
  final String target;
}

/// Petite carte : un point d'état, le libellé, la valeur. Discrète.
class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.item, required this.onTap});

  final _TodayItem item;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onTap(item.target),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(item.icon, size: 16, color: colors.ink2),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: item.tone.foreground(colors),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AmpereType.meta.copyWith(color: colors.ink3),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      item.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.bodyStrong.copyWith(
                        color: colors.ink,
                        fontFeatures: AmpereType.tabular,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
