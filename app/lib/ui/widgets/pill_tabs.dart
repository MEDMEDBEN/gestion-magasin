import 'package:flutter/material.dart';

import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';

/// Onglets d'un écran en pastilles (Vente, Catalogue…) : l'onglet choisi en
/// dégradé d'accent ; sur téléphone, les pastilles passent à la ligne.
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
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.lineSoft),
      ),
      child: Wrap(
        runSpacing: 4,
        children: [
          for (final (value, icon, label) in items)
            _tab(colors, value, icon, label),
        ],
      ),
    );
  }

  Widget _tab(AmpereColors colors, T value, IconData icon, String label) {
    final on = value == selected;
    final ink = on ? colors.onAccent : colors.ink2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onSelect(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: on
                  ? LinearGradient(colors: [colors.accent, colors.accentHi])
                  : null,
              boxShadow: on
                  ? [
                      BoxShadow(
                        color: colors.accent.withValues(alpha: 0.35),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: ink),
                const SizedBox(width: 7),
                Text(label, style: AmpereType.bodyStrong.copyWith(color: ink)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
