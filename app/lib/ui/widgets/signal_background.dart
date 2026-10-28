import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Fond animé « barres de LED » (demande MEDMEDBEN du 2026-10-28 : un magasin
/// de matériel électrique et électronique) :
/// allumé par défaut, **éteignable**, choix gardé par compte sur le poste
/// (comme le thème). Rangé dans les réglages locaux : ce n'est pas un secret.
class SignalBackgroundController extends Notifier<bool> {
  bool _chosen = false;

  static String _key(String userId) => 'signal_background.$userId';

  @override
  bool build() {
    _chosen = false;
    final userId = ref.watch(currentUserIdProvider);
    if (userId != null) _restore(userId);
    return true;
  }

  Future<void> _restore(String userId) async {
    final stored = await ref
        .read(localSettingsStoreProvider)
        .read(_key(userId));
    if (_chosen || !ref.mounted || ref.read(currentUserIdProvider) != userId) {
      return;
    }
    if (stored != null) state = stored == 'on';
  }

  Future<void> toggle() async {
    _chosen = true;
    state = !state;
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    await ref
        .read(localSettingsStoreProvider)
        .write(_key(userId), state ? 'on' : 'off');
  }
}

final signalBackgroundProvider =
    NotifierProvider<SignalBackgroundController, bool>(
      SignalBackgroundController.new,
    );

/// Rubans de LED parcourus d'un chenillard lumineux, et deux barres-graphes
/// (vumètres) de LED dans les coins du bas, dans des couleurs qui passent de
/// l'une à l'autre (pervenche → turquoise → violet). Discret : petites diodes,
/// halos doux, rien sous le pointeur.
///
/// Animation coupée si le système demande moins de mouvement : une image fixe
/// est alors dessinée.
class SignalBackground extends StatefulWidget {
  const SignalBackground({super.key, this.animate = true});

  /// `false` : image fixe (tests, captures, préférence d'accessibilité).
  final bool animate;

  @override
  State<SignalBackground> createState() => _SignalBackgroundState();
}

class _SignalBackgroundState extends State<SignalBackground>
    with SingleTickerProviderStateMixin {
  // Un tour complet = 36 s : lent, jamais agité. Les fréquences du dessin sont
  // entières, donc la boucle est sans raccord.
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 36),
    value: 0.3,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SignalBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final still = !widget.animate || MediaQuery.of(context).disableAnimations;
    if (still) {
      _clock.stop();
    } else if (!_clock.isAnimating) {
      _clock.repeat();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _SignalPainter(clock: _clock, dark: dark),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _SignalPainter extends CustomPainter {
  _SignalPainter({required this.clock, required this.dark})
    : super(repaint: clock);

  final Animation<double> clock;
  final bool dark;

  /// Les couleurs du cycle, accordées à la palette « bleu nuit ».
  static const _hues = [
    Color(0xFF5B7CFA), // pervenche
    Color(0xFF2DD4BF), // turquoise
    Color(0xFFA78BFA), // violet
  ];

  /// Couleur au point `u` du cycle, en fondu continu.
  static Color _hue(double u) {
    final x = (u % 1) * _hues.length;
    final i = x.floor();
    return Color.lerp(
      _hues[i % _hues.length],
      _hues[(i + 1) % _hues.length],
      x - i,
    )!;
  }

  static const _twoPi = 2 * math.pi;

  /// Une diode : halo (si assez allumée) puis le corps arrondi.
  void _led(
    Canvas canvas,
    Rect body,
    Color color,
    double level,
    double strength,
  ) {
    final lit = level.clamp(0.0, 1.0);
    if (lit > 0.35) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(body.inflate(4), const Radius.circular(6)),
        Paint()
          ..color = color.withValues(alpha: 0.28 * lit * strength)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, const Radius.circular(2)),
      Paint()..color = color.withValues(alpha: (0.10 + 0.75 * lit) * strength),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = clock.value;
    final w = size.width;
    final h = size.height;
    final strength = dark ? 1.0 : 0.55;

    // ── Rubans : des rangées de diodes, un chenillard qui court ─────────
    // Le long des bords (sous la barre du haut, en bas, sur les côtés) : là
    // où le contenu ne les cache pas. Entiers → boucle sans raccord.
    const pitch = 14.0;
    void strip(Offset from, Offset to, int dir, int waves, double hueShift) {
      final length = (to - from).distance;
      final count = (length / pitch).floor();
      final vertical = (to.dx - from.dx).abs() < (to.dy - from.dy).abs();
      for (var i = 0; i < count; i++) {
        final u = i / count;
        final phase = _twoPi * (u * 3 - t * dir * waves * 4);
        final wave = math.pow((math.sin(phase) + 1) / 2, 6).toDouble();
        final edge = math.sin(math.pi * u).clamp(0.0, 1.0);
        final level = (0.10 + 0.90 * wave) * edge;
        final center = Offset.lerp(from, to, (i + 0.5) / count)!;
        _led(
          canvas,
          Rect.fromCenter(
            center: center,
            width: vertical ? 3 : 8,
            height: vertical ? 8 : 3,
          ),
          _hue(u * 0.6 + t * 2 + hueShift),
          level,
          strength,
        );
      }
    }

    strip(Offset(0, 64), Offset(w, 64), -1, 1, 0.4);
    strip(Offset(0, h - 12), Offset(w, h - 12), 1, 2, 0);
    strip(Offset(12, h * 0.14), Offset(12, h * 0.62), 1, 1, 0.2);
    strip(Offset(w - 12, h * 0.14), Offset(w - 12, h * 0.62), -1, 1, 0.7);

    // ── Barres-graphes : colonnes de segments, comme un vumètre ─────────
    void meter(double left, bool mirror) {
      const columns = 8;
      const segments = 16;
      const colWidth = 12.0;
      const colGap = 6.0;
      const segHeight = 5.0;
      const segGap = 3.0;
      final bottom = h - 34;
      for (var c = 0; c < columns; c++) {
        final k = mirror ? columns - 1 - c : c;
        // Hauteur qui monte et descend en douceur (fréquences entières).
        final height =
            0.35 +
            0.3 * math.sin(_twoPi * (t * (2 + k % 3) + k * 0.13)) +
            0.2 * math.sin(_twoPi * (t * (5 - k % 2) + k * 0.37));
        final lit = (height.clamp(0.05, 1.0) * segments).round();
        final x = left + c * (colWidth + colGap);
        for (var g = 0; g < segments; g++) {
          final on = g < lit;
          // Du bas (pervenche) vers le haut (violet), le tout en cycle.
          final color = _hue(t * 2 + g / segments * 0.66);
          _led(
            canvas,
            Rect.fromLTWH(
              x,
              bottom - (g + 1) * (segHeight + segGap),
              colWidth,
              segHeight,
            ),
            color,
            on ? 0.9 : 0.05,
            strength,
          );
        }
      }
    }

    const meterWidth = 8 * 12.0 + 7 * 6.0;
    meter(28, false);
    meter(w - 28 - meterWidth, true);
  }

  @override
  bool shouldRepaint(_SignalPainter old) => old.dark != dark;
}
