import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';

/// Briques communes des écrans de travail (demande MEDMEDBEN du 2026-10-13 :
/// « jamais une page vide sans sens », les actions en boutons clairs, la
/// couleur qui DIT quelque chose). Rouge = à traiter tout de suite, ambre = à
/// surveiller, vert = en ordre, bleu = en cours / information.

/// Un chiffre clé coloré, cliquable comme filtre (« 3 en rupture »).
/// Pastille compacte sur une ligne (2026-10-13 : les tuiles étaient trop
/// grandes) ; choisie, elle prend la couleur de son état.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
    this.selected = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final StatusTone tone;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    // Maquette du 2026-10-26 : pastille blanche à filet ; choisie, pleine
    // (noir en clair). La couleur de l'état ne teinte que l'icône.
    final fg = selected ? colors.onAccent : colors.ink;
    return Material(
      color: selected ? colors.accent : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: selected ? colors.accent : colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? colors.onAccent : tone.foreground(colors),
              ),
              const SizedBox(width: 7),
              Text(
                value,
                style: AmpereType.bodyStrong.copyWith(
                  color: fg,
                  fontFeatures: AmpereType.tabular,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: AmpereType.meta.copyWith(
                  color: selected ? colors.onAccent : colors.ink2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rangée de [StatTile] : à la suite, à la ligne si besoin.
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 8, runSpacing: 8, children: children);
}

/// Une action expliquée : icône colorée, titre, une ligne de « pourquoi ».
/// Bien plus clair qu'une icône seule ou un menu caché.
class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tone,
    required this.onTap,
    this.prominent = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final StatusTone tone;
  final VoidCallback? onTap;

  /// L'action principale de l'écran : fond teinté.
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    // Maquette du 2026-10-26 : carte blanche à filet, icône dans un carré
    // bordé ; l'action principale est pleine (noir en clair).
    final ink = prominent ? colors.onAccent : colors.ink;
    final soft = prominent
        ? colors.onAccent.withValues(alpha: 0.75)
        : colors.ink3;
    return Material(
      color: prominent ? colors.accent : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: prominent ? colors.accent : colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: prominent
                      ? colors.onAccent.withValues(alpha: 0.12)
                      : colors.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: prominent
                        ? colors.onAccent.withValues(alpha: 0.2)
                        : colors.line,
                  ),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: prominent ? ink : tone.foreground(colors),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AmpereType.rowTitle.copyWith(color: ink),
                    ),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.meta.copyWith(color: soft),
                    ),
                  ],
                ),
              ),
              Icon(LucideIcons.chevronRight, size: 18, color: soft),
            ],
          ),
        ),
      ),
    );
  }
}

/// Grille d'[ActionTile] : 3 par ligne au poste, une par ligne sur téléphone.
class ActionGrid extends StatelessWidget {
  const ActionGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final perRow = constraints.maxWidth >= 900
          ? 3
          : constraints.maxWidth >= 560
          ? 2
          : 1;
      const gap = 12.0;
      final width = (constraints.maxWidth - gap * (perRow - 1)) / perRow;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

/// « Comment ça marche » : étapes numérotées, pour qu'un écran sans données
/// dise quand même quoi faire.
class GuideSteps extends StatelessWidget {
  const GuideSteps({
    super.key,
    required this.title,
    required this.steps,
    this.current,
  });

  final String title;

  /// (titre, explication) de chaque étape.
  final List<(String, String)> steps;

  /// Étape à mettre en avant (index), si l'écran sait où en est l'utilisateur.
  final int? current;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.lightbulb, size: 16, color: colors.ink2),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: AmpereType.label.copyWith(color: colors.ink2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 720;
              final items = [
                for (var i = 0; i < steps.length; i++)
                  _step(colors, i, steps[i].$1, steps[i].$2),
              ];
              return wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < items.length; i++) ...[
                          if (i > 0) const SizedBox(width: 12),
                          Expanded(child: items[i]),
                        ],
                      ],
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < items.length; i++) ...[
                          if (i > 0) const SizedBox(height: 10),
                          items[i],
                        ],
                      ],
                    );
            },
          ),
        ],
      ),
    );
  }

  Widget _step(AmpereColors colors, int i, String title, String text) {
    final on = current == i;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? colors.accent : colors.accentBg,
          ),
          child: Text(
            '${i + 1}',
            style: AmpereType.bodyStrong.copyWith(
              color: on ? colors.onAccent : colors.accent,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AmpereType.bodyStrong.copyWith(
                  color: on ? colors.accent : colors.ink,
                ),
              ),
              Text(text, style: AmpereType.meta.copyWith(color: colors.ink3)),
            ],
          ),
        ),
      ],
    );
  }
}
