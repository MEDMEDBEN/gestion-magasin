import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';

/// Les 6 états que CHAQUE écran de données doit savoir rendre
/// (`docs/design-system.md` §8, `docs/spec-fonctionnelle.md` §30).
///
/// `syncPending` est distinct de `success` : une opération non confirmée par le
/// serveur ne s'affiche JAMAIS comme définitive (`docs/context.md` §6).
enum ScreenStatus {
  loading,
  empty,
  noResults,
  error,
  success,
  offline,
  syncPending,
}

/// Squelettes aux dimensions réelles — §8 interdit la roue centrée pendant un
/// chargement de liste : elle ne dit rien de ce qui arrive.
class AmpereSkeletonList extends StatefulWidget {
  const AmpereSkeletonList({super.key, this.rows = 5, this.rowHeight = 64});

  final int rows;
  final double rowHeight;

  @override
  State<AmpereSkeletonList> createState() => _AmpereSkeletonListState();
}

class _AmpereSkeletonListState extends State<AmpereSkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AmpereGeometry.skeleton,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    // `prefers-reduced-motion` (§4) : on fige la pulsation si l'OS le demande.
    final animate = !MediaQuery.disableAnimationsOf(context);

    return ListView.separated(
      padding: const EdgeInsets.all(AmpereGeometry.screenMarginMobile),
      itemCount: widget.rows,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, _) => AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => Opacity(
          opacity: animate ? 0.45 + (_controller.value * 0.35) : 0.6,
          child: child,
        ),
        child: Container(
          height: widget.rowHeight,
          decoration: BoxDecoration(
            color: colors.surface2,
            borderRadius: BorderRadius.circular(
              AmpereGeometry.cardRadiusMobile,
            ),
          ),
        ),
      ),
    );
  }
}

/// Vue générique pour les états non-`success`.
///
/// Rédaction imposée par §8 : dire ce qui s'est passé, jamais le code technique,
/// et garantir que la saisie de l'utilisateur n'est pas perdue.
class ScreenStateView extends StatelessWidget {
  const ScreenStateView({
    super.key,
    required this.status,
    this.title,
    this.message,
    this.searchTerm,
    this.onRetry,
    this.retryLabel,
    this.action,
  });

  final ScreenStatus status;
  final String? title;
  final String? message;

  /// Terme recherché — l'état « aucun résultat » doit le reprendre (§8).
  final String? searchTerm;
  final VoidCallback? onRetry;
  final String? retryLabel;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    if (status == ScreenStatus.loading) {
      return const AmpereSkeletonList();
    }

    final (icon, tone, defaultTitle, defaultMessage) = switch (status) {
      ScreenStatus.empty => (
        LucideIcons.inbox,
        StatusTone.neutral,
        'Rien à afficher',
        'Aucune donnée pour le moment.',
      ),
      ScreenStatus.noResults => (
        LucideIcons.search,
        StatusTone.neutral,
        'Aucun résultat',
        searchTerm == null
            ? 'Aucun élément ne correspond.'
            : 'Aucun élément ne correspond à « $searchTerm ».',
      ),
      ScreenStatus.error => (
        LucideIcons.triangleAlert,
        StatusTone.error,
        'Action impossible',
        'Le serveur n’a pas répondu. Vos saisies sont conservées.',
      ),
      ScreenStatus.offline => (
        LucideIcons.cloudOff,
        StatusTone.warn,
        'Hors connexion',
        'Les données affichées peuvent être périmées. '
            'Vos opérations sont conservées et partiront au retour du réseau.',
      ),
      ScreenStatus.syncPending => (
        LucideIcons.refreshCw,
        StatusTone.warn,
        'En attente de synchronisation',
        'Enregistré sur cet appareil, pas encore confirmé par le serveur.',
      ),
      _ => (
        LucideIcons.circleCheck,
        StatusTone.ok,
        'Terminé',
        'L’opération a abouti.',
      ),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Pastille d'icône plutôt qu'une illustration (§8).
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: tone.background(colors),
                borderRadius: BorderRadius.circular(
                  AmpereGeometry.iconChipRadius,
                ),
              ),
              child: Icon(icon, size: 26, color: tone.foreground(colors)),
            ),
            const SizedBox(height: 14),
            Text(
              title ?? defaultTitle,
              textAlign: TextAlign.center,
              style: AmpereType.sectionTitle.copyWith(color: colors.ink),
            ),
            const SizedBox(height: 6),
            Text(
              message ?? defaultMessage,
              textAlign: TextAlign.center,
              style: AmpereType.body.copyWith(color: colors.ink2),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(LucideIcons.refreshCw, size: 17),
                label: Text(retryLabel ?? 'Réessayer'),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}

/// Indicateur de synchronisation — **permanent dans l'en-tête** (§7).
/// `✓ Synchronisé` · `⟳ N en attente` (nombre exact) · `⚠ N échouée(s)`.
class SyncIndicator extends StatelessWidget {
  const SyncIndicator({
    super.key,
    required this.pendingCount,
    this.rejectedCount = 0,
    this.isOffline = false,
    this.onTap,
  });

  final int pendingCount;
  final int rejectedCount;
  final bool isOffline;

  /// Ouvre le détail (file, rejets) — c'est le seul chemin vers un rejet.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    // Un rejet exige une action de l'utilisateur : il prime sur le reste.
    final (icon, tone, label) = rejectedCount > 0
        ? (
            LucideIcons.triangleAlert,
            StatusTone.error,
            '$rejectedCount échouée${rejectedCount > 1 ? 's' : ''}',
          )
        : isOffline
        ? (LucideIcons.cloudOff, StatusTone.warn, 'Hors ligne')
        : pendingCount > 0
        ? (LucideIcons.refreshCw, StatusTone.warn, '$pendingCount en attente')
        : (LucideIcons.check, StatusTone.ok, 'Synchronisé');

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: tone.background(colors),
        borderRadius: BorderRadius.circular(AmpereGeometry.pillRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: tone.foreground(colors)),
          const SizedBox(width: 6),
          // La couleur ne porte jamais l'info seule : le libellé est toujours là (§12.4).
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AmpereType.meta.copyWith(
                color: tone.foreground(colors),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return pill;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AmpereGeometry.pillRadius),
        child: pill,
      ),
    );
  }
}

/// Badge de statut (§6) — rayon 999, fond `-bg`, texte `-fg`, sans bordure.
class AmpereBadge extends StatelessWidget {
  const AmpereBadge({
    super.key,
    required this.label,
    required this.tone,
    this.icon,
  });

  final String label;
  final StatusTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: tone.background(colors),
        borderRadius: BorderRadius.circular(AmpereGeometry.pillRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: tone.foreground(colors)),
            const SizedBox(width: 5),
          ],
          // Élastique : au zoom texte (§12), le libellé s'abrège au lieu de
          // déborder de sa ligne.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AmpereType.metaDesktop.copyWith(
                color: tone.foreground(colors),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pastille d'icône (§6) — 34×34 desktop, 38 mobile, rayon 11.
class AmpereIconChip extends StatelessWidget {
  const AmpereIconChip({
    super.key,
    required this.icon,
    this.tone = StatusTone.info,
    this.size = 38,
  });

  final IconData icon;
  final StatusTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tone.background(colors),
        borderRadius: BorderRadius.circular(AmpereGeometry.iconChipRadius),
      ),
      child: Icon(icon, size: size * 0.48, color: tone.foreground(colors)),
    );
  }
}

/// Étiquette de champ AU-DESSUS (§6) : jamais un placeholder en guise d'étiquette.
class AmpereFieldLabel extends StatelessWidget {
  const AmpereFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: AmpereType.label.copyWith(color: AmpereColors.of(context).ink3),
      ),
    );
  }
}

/// Bandeau d'alerte en ligne (§7) — fond `-bg`, icône + texte du ton, action à droite.
class AmpereInlineAlert extends StatelessWidget {
  const AmpereInlineAlert({
    super.key,
    required this.message,
    this.tone = StatusTone.error,
    this.icon,
    this.action,
  });

  final String message;
  final StatusTone tone;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.background(colors),
        border: Border.all(
          color: tone.foreground(colors).withValues(alpha: 0.35),
          width: AmpereGeometry.borderWidth,
        ),
        borderRadius: BorderRadius.circular(AmpereGeometry.fieldRadiusMobile),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon ?? LucideIcons.triangleAlert,
            size: 15,
            color: tone.foreground(colors),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AmpereType.meta.copyWith(color: tone.foreground(colors)),
            ),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }
}
