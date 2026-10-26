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
    // Petit bouton (demande MEDMEDBEN du 2026-10-26 : les tuiles d'action
    // étaient trop grandes) ; l'explication passe en infobulle. L'action
    // principale est pleine, les autres bordées, icône à la couleur de l'état.
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12),
      ),
      textStyle: WidgetStatePropertyAll(AmpereType.bodyStrong),
      visualDensity: VisualDensity.compact,
    );
    return Tooltip(
      message: subtitle,
      child: prominent
          ? FilledButton.icon(
              style: style,
              onPressed: onTap,
              icon: Icon(icon, size: 15),
              label: Text(title),
            )
          : OutlinedButton.icon(
              style: style,
              onPressed: onTap,
              icon: Icon(icon, size: 15, color: tone.foreground(colors)),
              label: Text(title),
            ),
    );
  }
}

/// Rangée d'[ActionTile] : de petits boutons à la suite, à la ligne si besoin.
class ActionGrid extends StatelessWidget {
  const ActionGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 8, runSpacing: 8, children: children);
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
