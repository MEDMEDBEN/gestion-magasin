import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
    // Téléphone (2026-10-29) : UN bouton montre la rubrique en cours ; une
    // flèche déplie les autres. La zone de travail reste dégagée.
    if (MediaQuery.sizeOf(context).width < 600 && items.length > 1) {
      return _CompactTabs<T>(
        items: items,
        selected: selected,
        onSelect: onSelect,
      );
    }
    return Container(
      // Onglets « shadcn » (maquette du 2026-10-26) : fond gris doux,
      // l'onglet actif en carte blanche, sans couleur.
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      // Une seule ligne qui défile (téléphone) plutôt que deux lignes.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (value, icon, label) in items)
              _tab(colors, value, icon, label),
          ],
        ),
      ),
    );
  }

  Widget _tab(AmpereColors colors, T value, IconData icon, String label) {
    final on = value == selected;
    final ink = on ? colors.ink : colors.ink2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => onSelect(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              color: on ? colors.surface : null,
              boxShadow: on
                  ? const [
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 3,
                        offset: Offset(0, 1),
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

class _CompactTabs<T> extends StatefulWidget {
  const _CompactTabs({
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  final List<(T value, IconData icon, String label)> items;
  final T selected;
  final ValueChanged<T> onSelect;

  @override
  State<_CompactTabs<T>> createState() => _CompactTabsState<T>();
}

class _CompactTabsState<T> extends State<_CompactTabs<T>> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final current =
        widget.items.where((i) => i.$1 == widget.selected).firstOrNull ??
        widget.items.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: colors.surface2,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('deplier-onglets-${_open ? 'ouvert' : 'ferme'}'),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(current.$2, size: 16, color: colors.ink),
                  const SizedBox(width: 8),
                  Text(
                    current.$3,
                    style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                  ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: Icon(
                      LucideIcons.chevronDown,
                      size: 18,
                      color: colors.ink2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !_open
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (value, icon, label) in widget.items)
                        if (value != widget.selected)
                          ActionChip(
                            avatar: Icon(icon, size: 15, color: colors.ink2),
                            label: Text(label),
                            onPressed: () {
                              setState(() => _open = false);
                              widget.onSelect(value);
                            },
                          ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
