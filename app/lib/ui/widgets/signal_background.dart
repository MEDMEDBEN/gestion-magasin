import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Fond animé « signal électrique » (demande MEDMEDBEN du 2026-10-28) :
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

/// Ondes fines qui glissent lentement, traversées de salves lumineuses, dans
/// des couleurs qui passent de l'une à l'autre (pervenche → turquoise →
/// violet). Discret : traits de 1,4 px, bords fondus, rien sous le pointeur.
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

  /// Couleur au point `u` (0..1) du cycle, en fondu continu.
  static Color _hue(double u) {
    final x = (u % 1) * _hues.length;
    final i = x.floor();
    return Color.lerp(
      _hues[i % _hues.length],
      _hues[(i + 1) % _hues.length],
      x - i,
    )!;
  }

  /// Une onde : hauteur de base, amplitude, vitesses (entières : boucle sans
  /// raccord), décalage de couleur.
  static const _waves = [
    (base: 0.62, amp: 0.040, f: 1.5, k1: 1, k2: 2, burst: 1, hue: 0.0),
    (base: 0.72, amp: 0.055, f: 1.0, k1: -1, k2: 1, burst: 2, hue: 0.33),
    (base: 0.82, amp: 0.035, f: 2.2, k1: 2, k2: -1, burst: 1, hue: 0.66),
    (base: 0.20, amp: 0.025, f: 1.2, k1: -1, k2: 2, burst: 1, hue: 0.5),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = clock.value;
    final w = size.width;
    final h = size.height;
    final strength = dark ? 1.0 : 0.6;
    const twoPi = 2 * math.pi;

    for (final (i, wave) in _waves.indexed) {
      final color = _hue(t * 2 + wave.hue);
      final burstX = w * ((t * wave.burst + i * 0.27) % 1);
      final burstWidth = w * 0.035;

      double y(double x) {
        final u = x / w;
        final calm =
            math.sin(twoPi * (u * wave.f + t * wave.k1)) +
            0.5 * math.sin(twoPi * (u * wave.f * 2.3 + t * wave.k2));
        // Salve : une oscillation rapide, enveloppée d'une cloche, qui court
        // le long de l'onde — le « signal ».
        final d = (x - burstX) / burstWidth;
        final burst =
            1.2 * math.exp(-d * d) * math.sin(twoPi * x / (w * 0.011));
        return h * wave.base + h * wave.amp * (calm * 0.6 + burst);
      }

      final path = Path()..moveTo(0, y(0));
      for (var x = 3.0; x <= w; x += 3) {
        path.lineTo(x, y(x));
      }

      // Bords fondus : l'onde naît et meurt doucement.
      final shader = LinearGradient(
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: 0.55 * strength),
          color.withValues(alpha: 0.55 * strength),
          color.withValues(alpha: 0),
        ],
        stops: const [0, 0.18, 0.82, 1],
      ).createShader(Offset.zero & size);

      // Halo puis trait fin.
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..color = color.withValues(alpha: 0.10 * strength)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round
          ..shader = shader,
      );

      // L'étincelle au cœur de la salve.
      final spark = Offset(burstX, y(burstX));
      final fade = math.sin(math.pi * (burstX / w)).clamp(0.0, 1.0);
      canvas.drawCircle(
        spark,
        12,
        Paint()
          ..color = color.withValues(alpha: 0.22 * strength * fade)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
      canvas.drawCircle(
        spark,
        2.2,
        Paint()..color = color.withValues(alpha: 0.9 * strength * fade),
      );
    }
  }

  @override
  bool shouldRepaint(_SignalPainter old) => old.dark != dark;
}
