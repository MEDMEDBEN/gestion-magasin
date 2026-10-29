import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'motion.dart';
import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';

/// Briques communes des écrans de travail (demande MEDMEDBEN du 2026-10-13 :
/// « jamais une page vide sans sens », les actions en boutons clairs, la
/// couleur qui DIT quelque chose). Rouge = à traiter tout de suite, ambre = à
/// surveiller, vert = en ordre, bleu = en cours / information.

/// Carte d'information ou d'action : la carte du thème, avec en sombre un
/// léger dégradé pour la distinguer du fond (2026-10-28).
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({super.key, required this.child, this.clipBehavior});

  final Widget child;

  /// Gardé pour remplacer `Card` sans retouche ; le contenu est toujours
  /// découpé aux coins arrondis.
  final Clip? clipBehavior;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Ink(
      decoration: BoxDecoration(
        gradient: AmpereColors.of(context).cardGradient,
      ),
      child: child,
    ),
  );
}

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
    // FILTRE ≠ ACTION (demande MEDMEDBEN du 2026-10-29) : un filtre est une
    // PILULE au fond doux, sans relief ; choisi, il s'entoure de l'accent et
    // prend une coche. Les actions, elles, sont des boutons rectangulaires.
    final fg = selected ? colors.accent : colors.ink;
    return Material(
      color: selected ? colors.accentBg : colors.surface2,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? colors.accent : Colors.transparent,
          width: 1.4,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(12, 6, 14, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Icon(
                  selected ? LucideIcons.check : icon,
                  key: ValueKey(selected),
                  size: 14,
                  color: selected ? colors.accent : tone.foreground(colors),
                ),
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
              // Petit écran : le libellé se raccourcit plutôt que déborder.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AmpereType.meta.copyWith(
                    color: selected ? colors.accent : colors.ink2,
                  ),
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
  Widget build(BuildContext context) {
    // Téléphone (2026-10-29) : seul le filtre EN COURS est montré, une flèche
    // déplie les autres — l'écran de travail reste dégagé.
    if (_isPhone(context) && children.length > 1) {
      final current =
          children.whereType<StatTile>().where((t) => t.selected).firstOrNull ??
          children.first;
      return _Expandable(
        icon: LucideIcons.listFilter,
        label: 'Filtres',
        visible: current,
        all: children,
      );
    }
    return Wrap(spacing: 8, runSpacing: 8, children: children);
  }
}

/// Téléphone : largeur sous 600 px.
bool _isPhone(BuildContext context) => MediaQuery.sizeOf(context).width < 600;

/// Ce qui est montré tout de suite (`visible`), un bouton à flèche qui déplie
/// le reste (`all`) en douceur ; replié par défaut.
class _Expandable extends StatefulWidget {
  const _Expandable({
    required this.icon,
    required this.label,
    required this.visible,
    required this.all,
  });

  final IconData icon;
  final String label;
  final Widget visible;
  final List<Widget> all;

  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final others = [
      for (final c in widget.all)
        if (!identical(c, widget.visible)) c,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(child: widget.visible),
            const SizedBox(width: 8),
            Material(
              color: _open ? colors.accentBg : colors.surface2,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                // Clé lisible par les tests : `deplier-<libellé>-ferme|ouvert`.
                key: ValueKey(
                  'deplier-${widget.label}-${_open ? 'ouvert' : 'ferme'}',
                ),
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, size: 14, color: colors.ink2),
                      const SizedBox(width: 6),
                      Text(
                        '${widget.label} · ${others.length}',
                        style: AmpereType.meta.copyWith(
                          color: colors.ink2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 2),
                      AnimatedRotation(
                        turns: _open ? 0.5 : 0,
                        duration: const Duration(milliseconds: 220),
                        child: Icon(
                          LucideIcons.chevronDown,
                          size: 15,
                          color: colors.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? Appear(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(spacing: 8, runSpacing: 8, children: others),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
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
    // Action = bouton rectangulaire avec un léger relief (≠ filtre pilule).
    final style = ButtonStyle(
      elevation: const WidgetStatePropertyAll(1.5),
      shadowColor: WidgetStatePropertyAll(colors.ink.withValues(alpha: 0.25)),
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
  Widget build(BuildContext context) {
    // Téléphone (2026-10-29) : l'action PRINCIPALE reste en vue, les autres
    // se rangent derrière « Actions ▾ ».
    if (_isPhone(context) && children.length > 1) {
      final main =
          children
              .whereType<ActionTile>()
              .where((a) => a.prominent)
              .firstOrNull ??
          children.first;
      return _Expandable(
        icon: LucideIcons.layoutGrid,
        label: 'Actions',
        visible: main,
        all: children,
      );
    }
    return Wrap(spacing: 8, runSpacing: 8, children: children);
  }
}

/// « Comment ça marche » : étapes numérotées, pour qu'un écran sans données
/// dise quand même quoi faire.
class GuideSteps extends StatefulWidget {
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
  State<GuideSteps> createState() => _GuideStepsState();
}

class _GuideStepsState extends State<GuideSteps> {
  /// Téléphone (2026-10-29) : replié en une ligne, un toucher l'ouvre.
  late bool _open = !_isPhone(context);

  String get title => widget.title;
  List<(String, String)> get steps => widget.steps;
  int? get current => widget.current;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final phone = _isPhone(context);
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
          InkWell(
            onTap: phone ? () => setState(() => _open = !_open) : null,
            child: Row(
              children: [
                Icon(LucideIcons.lightbulb, size: 16, color: colors.ink2),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AmpereType.label.copyWith(color: colors.ink2),
                      ),
                      if (!_open)
                        Text(
                          [for (final s in steps) s.$1].join(' → '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AmpereType.meta.copyWith(color: colors.ink3),
                        ),
                    ],
                  ),
                ),
                if (phone)
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: Icon(
                      LucideIcons.chevronDown,
                      size: 17,
                      color: colors.ink2,
                    ),
                  ),
              ],
            ),
          ),
          if (_open) ...[
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

/// Marge du bas d'une liste qui défile DERRIÈRE la barre de verre du
/// téléphone (2026-10-29) : la hauteur de la barre s'ajoute, pour que le
/// dernier élément reste atteignable. Sans barre (poste), rien ne change.
EdgeInsetsGeometry withNavBar(
  BuildContext context,
  EdgeInsetsGeometry padding,
) => padding.add(EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom));

/// Champ de recherche sûr sur téléphone (bug terrain du 2026-10-29 : « led »
/// tapé dans le navigateur d'un téléphone cherchait « del »). Si la position
/// du curseur se perd (sélection invalide), le navigateur insère la lettre
/// suivante AU DÉBUT : le texte s'écrit à l'envers. Ici, une sélection
/// invalide remet le curseur en fin de texte.
class SearchField extends TextEditingController {
  @override
  set value(TextEditingValue newValue) {
    super.value = newValue.selection.isValid || newValue.text.isEmpty
        ? newValue
        : newValue.copyWith(
            selection: TextSelection.collapsed(offset: newValue.text.length),
          );
  }
}
