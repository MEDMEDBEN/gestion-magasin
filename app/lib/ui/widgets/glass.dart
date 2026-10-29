import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
  const SideIsland({
    super.key,
    required this.buttons,
    this.collapsed = false,
    this.onToggle,
    this.right = false,
  });

  final List<IslandButton> buttons;

  /// Collée au bord DROIT (téléphone, sous le pouce) plutôt qu'au gauche.
  final bool right;

  /// Réduite (2026-10-29) : une fine languette noire avec une poignée.
  final bool collapsed;

  /// Réduire / déployer ; `null` : pas réductible.
  final VoidCallback? onToggle;

  static const width = 70.0;

  /// Largeur de la languette réduite.
  static const collapsedWidth = 16.0;

  static const _spring = Duration(milliseconds: 520);

  @override
  Widget build(BuildContext context) {
    final toggle = onToggle;
    final open = 80.0 + buttons.length * 48 + (buttons.length - 1) * 16 + 44;
    return AnimatedContainer(
      // Mouvement souple, léger rebond (façon iOS).
      duration: _spring,
      curve: Curves.easeOutBack,
      width: collapsed ? collapsedWidth : width,
      height: collapsed ? 96 : open,
      child: CustomPaint(
        painter: _IslandPainter(right: right),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: animation, child: child),
          ),
          child: collapsed
              ? _Grabber(key: const ValueKey('reduite'), onTap: toggle)
              : OverflowBox(
                  key: const ValueKey('deployee'),
                  minWidth: width,
                  maxWidth: width,
                  minHeight: open,
                  maxHeight: open,
                  alignment: right
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(11, 40, 11, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (i, b) in buttons.indexed) ...[
                          if (i > 0) const SizedBox(height: 16),
                          _IslandButtonView(button: b),
                        ],
                        if (toggle != null) ...[
                          const SizedBox(height: 12),
                          Tooltip(
                            message: 'Réduire',
                            child: InkResponse(
                              onTap: toggle,
                              radius: 18,
                              child: SizedBox(
                                width: 32,
                                height: 32,
                                child: Icon(
                                  right
                                      ? LucideIcons.chevronRight
                                      : LucideIcons.chevronLeft,
                                  size: 20,
                                  color: const Color(0xFF94A3B8),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Languette réduite : une poignée claire, toute la languette est cliquable.
class _Grabber extends StatefulWidget {
  const _Grabber({super.key, required this.onTap});

  final VoidCallback? onTap;

  @override
  State<_Grabber> createState() => _GrabberState();
}

class _GrabberState extends State<_Grabber> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Déployer',
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 4,
            height: _hover ? 40 : 30,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: _hover ? 0.8 : 0.45),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    ),
  );
}

class _IslandPainter extends CustomPainter {
  _IslandPainter({this.right = false});

  final bool right;

  @override
  void paint(Canvas canvas, Size size) {
    if (right) {
      // Même forme, en miroir : collée au bord droit.
      canvas
        ..translate(size.width, 0)
        ..scale(-1, 1);
    }
    const c = 22.0; // raccord concave
    final h = size.height;
    final w = size.width;
    // Arrondi côté écran : jamais plus que la moitié de la largeur.
    final r = math.min(30.0, w).clamp(1.0, h / 2);
    final path = Path()
      ..moveTo(0, -c)
      // Raccord concave du haut.
      ..quadraticBezierTo(0, 0, c.clamp(0, w), 0)
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w, r), radius: Radius.circular(r))
      ..lineTo(w, h - r)
      ..arcToPoint(Offset(w - r, h), radius: Radius.circular(r))
      ..lineTo(c.clamp(0, w), h)
      // Raccord concave du bas.
      ..quadraticBezierTo(0, h, 0, h + c)
      ..close();
    canvas.drawShadow(path, Colors.black, 12, false);
    canvas.drawPath(path, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(_IslandPainter old) => true;
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

/// Verre dépoli de la barre du téléphone (image fournie par MEDMEDBEN le
/// 2026-10-29) : voile blanc translucide, reflet en haut, filet blanc.
BoxDecoration _frost(bool dark, {required BorderRadius radius}) =>
    BoxDecoration(
      borderRadius: radius,
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: dark
            ? [
                Colors.white.withValues(alpha: 0.16),
                Colors.white.withValues(alpha: 0.06),
              ]
            : [
                Colors.white.withValues(alpha: 0.6),
                Colors.white.withValues(alpha: 0.28),
              ],
      ),
      border: Border.all(
        width: 1.2,
        color: Colors.white.withValues(alpha: dark ? 0.25 : 0.95),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.35 : 0.12),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
    );

/// Un panneau de verre dépoli (flou + voile `_frost`).
class _Frosted extends StatelessWidget {
  const _Frosted({required this.radius, required this.child});

  final BorderRadius radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = AmpereColors.of(context).isDark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: _frost(dark, radius: radius).boxShadow,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: DecoratedBox(
            decoration: _frost(dark, radius: radius).copyWith(boxShadow: []),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Un onglet de la barre du bas : icône au-dessus du libellé ; actif, il se
/// pose sur une pastille de verre plus claire.
class IslandTab extends StatelessWidget {
  const IslandTab({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final ink = active ? colors.ink : colors.ink2;
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 3),
            decoration: active
                ? _frost(
                    colors.isDark,
                    radius: BorderRadius.circular(24),
                  ).copyWith(boxShadow: [])
                : BoxDecoration(borderRadius: BorderRadius.circular(24)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Badge.count(
                  count: badge,
                  isLabelVisible: badge > 0,
                  child: Icon(icon, size: 21, color: ink),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Barre de navigation du téléphone : une CAPSULE de verre dépoli qui flotte
/// au-dessus du contenu (celui-ci défile derrière, flouté).
class BottomIsland extends StatelessWidget {
  const BottomIsland({super.key, required this.tabs});

  final List<IslandTab> tabs;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 6, 14, 10 + bottom),
      child: SizedBox(
        height: 62,
        child: Row(
          children: [
            Expanded(
              child: _Frosted(
                radius: BorderRadius.circular(31),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Row(children: tabs),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
