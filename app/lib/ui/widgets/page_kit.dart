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
    final fg = tone.foreground(colors);
    return Material(
      color: selected ? tone.background(colors) : colors.surface,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? fg : colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 6),
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
                  color: selected ? colors.ink : colors.ink2,
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
      Wrap(spacing: 6, runSpacing: 6, children: children);
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
    final fg = tone.foreground(colors);
    return Material(
      color: prominent ? tone.background(colors) : colors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: prominent ? fg : colors.line),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: prominent ? fg : tone.background(colors),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 20, color: prominent ? colors.bg : fg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AmpereType.rowTitle.copyWith(color: colors.ink),
                    ),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.meta.copyWith(color: colors.ink3),
                    ),
                  ],
                ),
              ),
              Icon(LucideIcons.chevronRight, size: 18, color: colors.ink3),
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
      const gap = 8.0;
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
        border: Border.all(color: colors.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.lightbulb, size: 16, color: colors.info),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: AmpereType.label.copyWith(color: colors.info),
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
