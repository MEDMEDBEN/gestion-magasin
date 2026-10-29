import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import '../theme/palettes.dart';
import 'signal_background.dart';

/// Réglages d'ambiance partagés par le poste (barre du haut) et le téléphone
/// (encoche latérale) : palette de couleurs, lumières de fond.
class PalettePanel extends ConsumerWidget {
  const PalettePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final current = currentPalette(ref);
    Widget row(String title, bool dark) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: AmpereType.label.copyWith(color: colors.ink3),
        ),
        const SizedBox(height: 8),
        Wrap(
          runSpacing: 8,
          children: [
            for (final p in AppPalette.values.where((p) => p.dark == dark))
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _PaletteChip(
                  palette: p,
                  selected: p == current,
                  onTap: () => ref.read(paletteProvider.notifier).set(p),
                ),
              ),
          ],
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Palette', style: AmpereType.h4.copyWith(color: colors.ink)),
          const SizedBox(height: 12),
          row('Clairs', false),
          const SizedBox(height: 14),
          row('Sombres', true),
        ],
      ),
    );
  }
}

/// Une palette : aperçu (fond, surface, accent) et son nom.
class _PaletteChip extends StatelessWidget {
  const _PaletteChip({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final p = palette.desktop;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Palette ${palette.label}',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: 92,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? colors.accent : colors.line,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              // Mini-écran : fond, une carte, une barre d'accent.
              Container(
                height: 46,
                decoration: BoxDecoration(
                  color: p.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: p.line),
                ),
                padding: const EdgeInsets.all(6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      decoration: BoxDecoration(
                        color: p.surface,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: p.line),
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Container(
                          width: 30,
                          height: 8,
                          decoration: BoxDecoration(
                            color: p.accent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(width: 4),
                        for (final c in palette.ledHues.take(2))
                          Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.only(right: 3),
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                palette.label,
                style: AmpereType.meta.copyWith(
                  color: colors.ink,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lumières : allumer/éteindre les LED, leur couleur, l'ambiance.
class LightsPanel extends ConsumerWidget {
  const LightsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final on = ref.watch(signalBackgroundProvider);
    final style = ref.watch(ledStyleProvider);
    final paletteHues = currentPalette(ref).ledHues;
    final led = ref.read(ledStyleProvider.notifier);
    return SizedBox(
      width: 320,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Lumières',
                    style: AmpereType.h4.copyWith(color: colors.ink),
                  ),
                ),
                Switch(
                  value: on,
                  onChanged: (_) =>
                      ref.read(signalBackgroundProvider.notifier).toggle(),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'COULEUR DES LED',
              style: AmpereType.label.copyWith(color: colors.ink3),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in LedColors.values)
                  Tooltip(
                    message: c.label,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => led.set(colors: c),
                      child: Container(
                        width: 34,
                        height: 34,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: c == style.colors
                                ? colors.accent
                                : colors.line,
                            width: c == style.colors ? 2 : 1,
                          ),
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: SweepGradient(
                              colors: [
                                ...c.hues(paletteHues),
                                c.hues(paletteHues).first,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              style.colors.label,
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
            const SizedBox(height: 14),
            Text(
              'AMBIANCE',
              style: AmpereType.label.copyWith(color: colors.ink3),
            ),
            const SizedBox(height: 8),
            SegmentedButton<LedAmbiance>(
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              showSelectedIcon: false,
              segments: [
                for (final a in LedAmbiance.values)
                  ButtonSegment(value: a, label: Text(a.label)),
              ],
              selected: {style.ambiance},
              onSelectionChanged: (v) => led.set(ambiance: v.first),
            ),
          ],
        ),
      ),
    );
  }
}
