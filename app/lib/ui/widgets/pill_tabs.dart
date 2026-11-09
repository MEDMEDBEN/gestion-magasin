import 'package:flutter/material.dart';

import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import 'motion.dart';

/// Onglets d'un écran (Vente, Catalogue…) : tous visibles, l'onglet choisi
/// plein en couleur d'accent ; sur téléphone, segments de même largeur.
class PillTabs<T> extends StatelessWidget {
  const PillTabs({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  final List<(T value, IconData icon, String label)> items;
  final T selected;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    // TOUTES les rubriques restent visibles (demande MEDMEDBEN du 2026-11-09 :
    // repliées derrière un bouton, on ne voyait pas qu'il y avait d'autres
    // pages). Téléphone : segments de même largeur, icône sur libellé.
    final phone = MediaQuery.sizeOf(context).width < 600 && items.length > 1;
    final index = items.indexWhere((i) => i.$1 == selected);
    final selection = SlidingSelection(
      expand: phone,
      selected: index < 0 ? null : index,
      // L'onglet actif : plein, couleur d'accent — impossible à confondre.
      indicator: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: colors.accent,
            boxShadow: [
              BoxShadow(
                color: colors.accent.withValues(alpha: 0.30),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
        ),
      ),
      children: [
        for (final (value, icon, label) in items)
          _tab(colors, value, icon, label, phone),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line),
      ),
      child: phone
          ? selection
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: selection,
            ),
    );
  }

  Widget _tab(
    AmpereColors colors,
    T value,
    IconData icon,
    String label,
    bool phone,
  ) {
    final on = value == selected;
    final ink = on ? colors.onAccent : colors.ink2;
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: (phone ? AmpereType.label : AmpereType.bodyStrong).copyWith(
        color: ink,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: () => onSelect(value),
          child: Padding(
            padding: phone
                ? const EdgeInsets.symmetric(horizontal: 2, vertical: 6)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: phone
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 18, color: ink),
                      const SizedBox(height: 3),
                      text,
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 17, color: ink),
                      const SizedBox(width: 8),
                      text,
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
