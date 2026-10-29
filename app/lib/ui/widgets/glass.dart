import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/ampere_colors.dart';

/// Style « verre » façon iOS / macOS, pour le thème BLANC (demande MEDMEDBEN
/// du 2026-10-28) : fond liquide (taches de couleur floues qui flottent),
/// surfaces en verre dépoli, encoche noire sur le bord gauche.

/// Fond liquide : trois grandes taches floues (bleu, indigo, cyan) qui
/// dérivent lentement. Image fixe si le système demande moins d'animations.
class LiquidBackground extends StatefulWidget {
  const LiquidBackground({super.key, this.animate = true});

  /// `false` : taches immobiles (lumières éteintes, tests).
  final bool animate;

  @override
  State<LiquidBackground> createState() => _LiquidBackgroundState();
}

class _LiquidBackgroundState extends State<LiquidBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(LiquidBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (!widget.animate || MediaQuery.of(context).disableAnimations) {
      _clock.stop();
    } else if (!_clock.isAnimating) {
      _clock.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _BlobPainter(_clock, AmpereColors.of(context)),
        size: Size.infinite,
      ),
    ),
  );
}

class _BlobPainter extends CustomPainter {
  _BlobPainter(this.clock, this.colors) : super(repaint: clock);

  final Animation<double> clock;
  final AmpereColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final t = Curves.easeInOut.transform(clock.value);
    final w = size.width;
    final h = size.height;
    // (centre relatif, rayon, couleur, déphasage)
    final blobs = [
      // Les couleurs de la palette : accent, secondaire, information.
      (const Offset(0.12, 0.05), 300.0, colors.accent, 0.0),
      (const Offset(0.92, 0.95), 260.0, colors.vizAlt, 0.35),
      (const Offset(0.55, 0.55), 220.0, colors.info, 0.7),
    ];
    for (final (center, radius, color, phase) in blobs) {
      final u = (t + phase) % 1;
      final dx = 40 * math.sin(math.pi * 2 * u);
      final dy = 30 * math.cos(math.pi * 2 * u);
      final scale = 1 + 0.1 * math.sin(math.pi * u);
      canvas.drawCircle(
        Offset(center.dx * w + dx, center.dy * h + dy),
        radius * scale,
        Paint()
          ..color = color.withValues(alpha: colors.isDark ? 0.22 : 0.32)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 90),
      );
    }
  }

  @override
  bool shouldRepaint(_BlobPainter old) => old.colors != colors;
}

/// Surface en verre dépoli : flou de ce qui est derrière, voile blanc
/// translucide, filet clair, ombre douce.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 20,
    this.opacity = 0.55,
    this.blur = 22,
  });

  final Widget child;
  final double radius;
  final double opacity;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final dark = colors.isDark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Color(dark ? 0x40000000 : 0x14000000),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // Clair : voile blanc ; sombre : voile de la surface.
              color: (dark ? colors.surface : Colors.white).withValues(
                alpha: dark ? opacity + 0.15 : opacity,
              ),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: Colors.white.withValues(alpha: dark ? 0.08 : 0.8),
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Un bouton de l'encoche : rond, infobulle au survol.
typedef IslandButton = ({
  IconData icon,
  String tooltip,
  bool active,
  VoidCallback onTap,
});

/// Encoche noire collée au bord gauche (« Dynamic Island » latérale), avec
/// ses raccords arrondis concaves en haut et en bas.
class SideIsland extends StatelessWidget {
  const SideIsland({super.key, required this.buttons});

  final List<IslandButton> buttons;

  static const width = 70.0;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _IslandPainter(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 11),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, b) in buttons.indexed) ...[
              if (i > 0) const SizedBox(height: 16),
              _IslandButtonView(button: b),
            ],
          ],
        ),
      ),
    );
  }
}

class _IslandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const r = 30.0; // arrondi côté écran
    const c = 22.0; // raccord concave
    final h = size.height;
    final w = SideIsland.width;
    final path = Path()
      ..moveTo(0, -c)
      // Raccord concave du haut.
      ..quadraticBezierTo(0, 0, c, 0)
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w, r), radius: const Radius.circular(r))
      ..lineTo(w, h - r)
      ..arcToPoint(Offset(w - r, h), radius: const Radius.circular(r))
      ..lineTo(c, h)
      // Raccord concave du bas.
      ..quadraticBezierTo(0, h, 0, h + c)
      ..close();
    canvas.drawShadow(path, Colors.black, 12, false);
    canvas.drawPath(path, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(_IslandPainter old) => false;
}

class _IslandButtonView extends StatefulWidget {
  const _IslandButtonView({required this.button});

  final IslandButton button;

  @override
  State<_IslandButtonView> createState() => _IslandButtonViewState();
}

class _IslandButtonViewState extends State<_IslandButtonView> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final b = widget.button;
    return Tooltip(
      message: b.tooltip,
      preferBelow: false,
      verticalOffset: 0,
      margin: const EdgeInsets.only(left: 64),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: b.onTap,
          child: Semantics(
            button: true,
            selected: b.active,
            label: b.tooltip,
            child: AnimatedScale(
              scale: _hover && !b.active ? 1.08 : 1,
              duration: const Duration(milliseconds: 200),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: b.active
                      ? AmpereColors.of(context).accentGradient
                      : null,
                  color: b.active
                      ? null
                      : Colors.white.withValues(alpha: _hover ? 0.18 : 0.08),
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: b.active ? 0.3 : 0.12,
                    ),
                  ),
                  boxShadow: b.active
                      ? [
                          BoxShadow(
                            color: AmpereColors.of(
                              context,
                            ).accent.withValues(alpha: 0.4),
                            blurRadius: 15,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: Icon(
                  b.icon,
                  size: 19,
                  color: b.active
                      ? AmpereColors.of(context).onAccent
                      : _hover
                      ? Colors.white
                      : const Color(0xFF94A3B8),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cadre noir fin autour de tout l'écran (demande MEDMEDBEN du 2026-10-29) :
/// l'encoche latérale en fait partie, comme le bord d'un iPhone.
class ScreenFrame extends StatelessWidget {
  const ScreenFrame({super.key});

  /// Épaisseur du cadre.
  static const width = 6.0;

  /// Arrondi intérieur des coins.
  static const radius = 22.0;

  @override
  Widget build(BuildContext context) =>
      IgnorePointer(child: CustomPaint(painter: _FramePainter()));
}

class _FramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final outer = Offset.zero & size;
    final inner = RRect.fromRectAndRadius(
      outer.deflate(ScreenFrame.width),
      const Radius.circular(ScreenFrame.radius),
    );
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(outer)
        ..addRRect(inner),
      Paint()..color = Colors.black,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => false;
}
