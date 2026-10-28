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

/// Couleur des LED (demande MEDMEDBEN du 2026-10-28).
enum LedColors {
  palette('Palette'),
  arcEnCiel('Arc-en-ciel'),
  cyan('Cyan'),
  magenta('Magenta'),
  vert('Vert néon'),
  ambre('Ambre');

  const LedColors(this.label);

  final String label;

  /// Couleurs du cycle ; `palette` : celles de la palette en vigueur.
  List<Color> hues(List<Color> fromPalette) => switch (this) {
    palette => fromPalette,
    arcEnCiel => const [
      Color(0xFFFF3D7F),
      Color(0xFFFFB020),
      Color(0xFF3DFFB0),
      Color(0xFF3DB8FF),
      Color(0xFFA066FF),
    ],
    cyan => const [Color(0xFF22E4FF), Color(0xFF3D8BFF)],
    magenta => const [Color(0xFFFF3DCB), Color(0xFFB04DFF)],
    vert => const [Color(0xFF2BFF9E), Color(0xFFB6FF3D)],
    ambre => const [Color(0xFFFFB020), Color(0xFFFF6A3D)],
  };
}

/// Ambiance lumineuse : intensité des LED et de leurs halos.
enum LedAmbiance {
  douce('Douce', 0.5),
  normale('Normale', 1.0),
  vive('Vive', 1.6);

  const LedAmbiance(this.label, this.intensity);

  final String label;
  final double intensity;
}

typedef LedStyle = ({LedColors colors, LedAmbiance ambiance});

/// Couleur et ambiance des LED, gardées par compte sur le poste.
class LedStyleController extends Notifier<LedStyle> {
  bool _chosen = false;

  static String _key(String userId) => 'led_style.$userId';

  static const _default = (
    colors: LedColors.palette,
    ambiance: LedAmbiance.normale,
  );

  @override
  LedStyle build() {
    _chosen = false;
    final userId = ref.watch(currentUserIdProvider);
    if (userId != null) _restore(userId);
    return _default;
  }

  Future<void> _restore(String userId) async {
    final stored = await ref
        .read(localSettingsStoreProvider)
        .read(_key(userId));
    if (_chosen ||
        stored == null ||
        !ref.mounted ||
        ref.read(currentUserIdProvider) != userId) {
      return;
    }
    final [colors, ambiance] = [...stored.split('|'), '', ''].take(2).toList();
    state = (
      colors:
          LedColors.values.where((c) => c.name == colors).firstOrNull ??
          _default.colors,
      ambiance:
          LedAmbiance.values.where((a) => a.name == ambiance).firstOrNull ??
          _default.ambiance,
    );
  }

  Future<void> set({LedColors? colors, LedAmbiance? ambiance}) async {
    _chosen = true;
    state = (
      colors: colors ?? state.colors,
      ambiance: ambiance ?? state.ambiance,
    );
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    await ref
        .read(localSettingsStoreProvider)
        .write(_key(userId), '${state.colors.name}|${state.ambiance.name}');
  }
}

final ledStyleProvider = NotifierProvider<LedStyleController, LedStyle>(
  LedStyleController.new,
);

/// Rubans de LED CONTINUS parcourus d'une lumière qui glisse, et des barres
/// de LED continues (tubes lumineux) qui montent et descendent dans les coins
/// du bas, dans des couleurs qui passent de l'une à l'autre. Discret : traits
/// fins, halos doux, rien sous le pointeur.
///
/// Animation coupée si le système demande moins de mouvement : une image fixe
/// est alors dessinée.
class SignalBackground extends StatefulWidget {
  const SignalBackground({
    super.key,
    required this.hues,
    this.intensity = 1,
    this.animate = true,
  });

  /// Couleurs du cycle des LED.
  final List<Color> hues;

  /// Ambiance : 0,5 douce … 1,6 vive.
  final double intensity;

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
          painter: _SignalPainter(
            clock: _clock,
            dark: dark,
            hues: widget.hues,
            intensity: widget.intensity,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _SignalPainter extends CustomPainter {
  _SignalPainter({
    required this.clock,
    required this.dark,
    required this.hues,
    required this.intensity,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final bool dark;
  final List<Color> hues;
  final double intensity;

  /// Couleur au point `u` du cycle, en fondu continu.
  Color _hue(double u) {
    final x = (u % 1) * hues.length;
    final i = x.floor();
    return Color.lerp(
      hues[i % hues.length],
      hues[(i + 1) % hues.length],
      x - i,
    )!;
  }

  static const _twoPi = 2 * math.pi;

  double _alpha(double a) => a.clamp(0.0, 1.0);

  /// Ruban de LED CONTINU (demande MEDMEDBEN du 2026-10-28 : « en ligne
  /// continue, pas coupé ») : une ligne fine aux couleurs du cycle, parcourue
  /// d'une lumière qui glisse ; bords fondus.
  void _ribbon(
    Canvas canvas,
    Offset from,
    Offset to,
    double t,
    int dir,
    double hueShift,
    double strength,
  ) {
    final rect = Rect.fromPoints(from, to).inflate(8);
    final colorsAlong = [
      for (var k = 0; k <= 6; k++) _hue(k / 6 * 0.6 + t * 2 + hueShift),
    ];
    // Ligne de fond, toujours allumée faiblement.
    canvas.drawLine(
      from,
      to,
      Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          begin: Alignment(
            from.dx <= to.dx ? -1 : 1,
            from.dy <= to.dy ? -1 : 1,
          ),
          end: Alignment(from.dx <= to.dx ? 1 : -1, from.dy <= to.dy ? 1 : -1),
          colors: [
            for (final (k, c) in colorsAlong.indexed)
              c.withValues(
                alpha: _alpha(
                  0.22 * strength * math.sin(math.pi * k / 6).clamp(0.15, 1),
                ),
              ),
          ],
        ).createShader(rect),
    );
    // La lumière qui court : une zone vive qui glisse le long du ruban.
    final p = (t * 3 * dir) % 1;
    final c = _hue(p * 0.6 + t * 2 + hueShift);
    final lo = (p - 0.14).clamp(0.0, 1.0);
    final hi = (p + 0.14).clamp(0.0, 1.0);
    final fade = math.sin(math.pi * p).clamp(0.0, 1.0);
    final glowShader = LinearGradient(
      begin: Alignment(from.dx <= to.dx ? -1 : 1, from.dy <= to.dy ? -1 : 1),
      end: Alignment(from.dx <= to.dx ? 1 : -1, from.dy <= to.dy ? 1 : -1),
      colors: [
        c.withValues(alpha: 0),
        c.withValues(alpha: _alpha(0.95 * strength * fade)),
        c.withValues(alpha: 0),
      ],
      stops: [lo, p.clamp(lo, hi), hi],
    );
    canvas.drawLine(
      from,
      to,
      Paint()
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7)
        ..shader = glowShader.createShader(rect),
    );
    canvas.drawLine(
      from,
      to,
      Paint()
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..shader = glowShader.createShader(rect),
    );
  }

  /// Barre de LED verticale continue (tube lumineux) qui monte et descend.
  void _bar(
    Canvas canvas,
    double x,
    double bottom,
    double maxHeight,
    double level,
    double t,
    double hueShift,
    double strength,
  ) {
    const width = 5.0;
    final track = RRect.fromLTRBR(
      x,
      bottom - maxHeight,
      x + width,
      bottom,
      const Radius.circular(3),
    );
    // Rail éteint.
    canvas.drawRRect(
      track,
      Paint()
        ..color = _hue(
          t * 2 + hueShift,
        ).withValues(alpha: _alpha(0.07 * strength)),
    );
    final height = maxHeight * level.clamp(0.05, 1.0);
    final lit = RRect.fromLTRBR(
      x,
      bottom - height,
      x + width,
      bottom,
      const Radius.circular(3),
    );
    final base = _hue(t * 2 + hueShift);
    final top = _hue(t * 2 + hueShift + 0.33);
    final shader = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [
        base.withValues(alpha: _alpha(0.9 * strength)),
        top.withValues(alpha: _alpha(0.75 * strength)),
      ],
    ).createShader(lit.outerRect);
    // Halo puis tube.
    canvas.drawRRect(
      lit.inflate(3),
      Paint()
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
        ..shader = shader,
    );
    canvas.drawRRect(lit, Paint()..shader = shader);
    // Point chaud au sommet.
    canvas.drawCircle(
      Offset(x + width / 2, bottom - height + 2),
      2.4,
      Paint()..color = Colors.white.withValues(alpha: _alpha(0.7 * strength)),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = clock.value;
    final w = size.width;
    final h = size.height;
    final strength = (dark ? 1.0 : 0.6) * intensity;

    // Rubans continus le long des bords.
    _ribbon(canvas, Offset(24, 64), Offset(w - 24, 64), t, -1, 0.4, strength);
    _ribbon(
      canvas,
      Offset(24, h - 12),
      Offset(w - 24, h - 12),
      t,
      1,
      0,
      strength,
    );
    _ribbon(
      canvas,
      Offset(12, h * 0.14),
      Offset(12, h * 0.6),
      t,
      1,
      0.2,
      strength,
    );
    _ribbon(
      canvas,
      Offset(w - 12, h * 0.14),
      Offset(w - 12, h * 0.6),
      t,
      -1,
      0.7,
      strength,
    );

    // Barres de LED continues dans les coins du bas (fréquences entières :
    // boucle sans raccord).
    const bars = 6;
    const gap = 13.0;
    final bottom = h - 34;
    final maxHeight = math.min(170.0, h * 0.26);
    for (var k = 0; k < bars; k++) {
      final level =
          0.45 +
          0.3 * math.sin(_twoPi * (t * (2 + k % 3) + k * 0.17)) +
          0.18 * math.sin(_twoPi * (t * (5 - k % 2) + k * 0.41));
      _bar(
        canvas,
        30 + k * gap,
        bottom,
        maxHeight,
        level,
        t,
        k * 0.05,
        strength,
      );
      _bar(
        canvas,
        w - 35 - k * gap,
        bottom,
        maxHeight,
        0.45 +
            0.3 * math.sin(_twoPi * (t * (3 - k % 2) + k * 0.23)) +
            0.18 * math.sin(_twoPi * (t * (4 + k % 3) + k * 0.31)),
        t,
        0.5 + k * 0.05,
        strength,
      );
    }
  }

  @override
  bool shouldRepaint(_SignalPainter old) =>
      old.dark != dark || old.hues != hues || old.intensity != intensity;
}
