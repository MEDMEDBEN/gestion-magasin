import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';

/// Ce que l'animation confirme.
enum FeedbackKind { success, pending, error }

/// Moment de la dernière pastille : les notifications qui la suivent de près
/// ne se doublent pas (`FeedbackMessenger`).
DateTime? lastFeedbackBurst;

/// Confirmation animée au centre de l'écran (demande MEDMEDBEN du
/// 2026-10-29 : « un effet qui fait comprendre ce qui se passe »).
///
/// Succès : pastille verte qui rebondit, coche tracée, onde qui s'élargit.
/// En attente (hors ligne) : pastille ambre, horloge. Refus : pastille rouge
/// qui tremble. Tout est piloté par UNE animation (≈ 1,6 s) qui se retire
/// seule — rien ne bloque l'écran ni ne laisse de minuterie derrière elle.
void showFeedbackBurst(
  BuildContext context,
  FeedbackKind kind,
  String title, {
  String? detail,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  lastFeedbackBurst = DateTime.now();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Burst(
      kind: kind,
      title: title,
      detail: detail,
      colors: AmpereColors.of(context),
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _Burst extends StatefulWidget {
  const _Burst({
    required this.kind,
    required this.title,
    required this.colors,
    required this.onDone,
    this.detail,
  });

  final FeedbackKind kind;
  final String title;
  final String? detail;
  final AmpereColors colors;
  final VoidCallback onDone;

  @override
  State<_Burst> createState() => _BurstState();
}

class _BurstState extends State<_Burst> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..forward().whenComplete(() => widget.onDone());

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Portion [a, b] de l'animation, ramenée à 0..1.
  double _seg(double a, double b, [Curve curve = Curves.easeOut]) =>
      curve.transform(((_c.value - a) / (b - a)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final tone = switch (widget.kind) {
      FeedbackKind.success => colors.ok,
      FeedbackKind.pending => colors.warn,
      FeedbackKind.error => colors.error,
    };
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          // Entrée 0-25 %, tenue, sortie 80-100 %.
          final appear = _seg(0, 0.25, Curves.elasticOut);
          final fade = 1 - _seg(0.8, 1, Curves.easeIn);
          final ring = _seg(0.08, 0.55);
          final draw = _seg(0.15, 0.45, Curves.easeInOut);
          final shake = widget.kind == FeedbackKind.error
              ? math.sin(_seg(0.12, 0.45, Curves.linear) * math.pi * 6) *
                    8 *
                    (1 - _seg(0.12, 0.45))
              : 0.0;
          return Opacity(
            opacity: fade,
            child: Stack(
              children: [
                // Voile léger : l'attention va au centre.
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.18 * _seg(0, 0.15)),
                  ),
                ),
                Center(
                  child: Transform.translate(
                    offset: Offset(shake, 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 180,
                          height: 180,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Onde qui s'élargit.
                              Container(
                                width: 96 + 84 * ring,
                                height: 96 + 84 * ring,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: tone.withValues(
                                      alpha: 0.5 * (1 - ring),
                                    ),
                                    width: 3,
                                  ),
                                ),
                              ),
                              Transform.scale(
                                scale: appear,
                                child: Container(
                                  width: 96,
                                  height: 96,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: tone,
                                    boxShadow: [
                                      BoxShadow(
                                        color: tone.withValues(alpha: 0.5),
                                        blurRadius: 30,
                                      ),
                                    ],
                                  ),
                                  child: widget.kind == FeedbackKind.success
                                      ? CustomPaint(painter: _Check(draw))
                                      : Icon(
                                          widget.kind == FeedbackKind.error
                                              ? LucideIcons.x
                                              : LucideIcons.clock,
                                          size: 44,
                                          color: Colors.white,
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Transform.translate(
                          offset: Offset(0, 12 * (1 - _seg(0.15, 0.4))),
                          child: Opacity(
                            opacity: _seg(0.15, 0.4),
                            child: _Label(
                              title: widget.title,
                              detail: widget.detail,
                              colors: colors,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.title, required this.colors, this.detail});

  final String title;
  final String? detail;
  final AmpereColors colors;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.line),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: AmpereType.h3.copyWith(color: colors.ink)),
              if (detail case final d?)
                Text(
                  d,
                  style: AmpereType.bodyStrong.copyWith(
                    color: colors.ink2,
                    fontFeatures: AmpereType.tabular,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Coche tracée progressivement (0 → 1).
class _Check extends CustomPainter {
  _Check(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.28, size.height * 0.52)
      ..lineTo(size.width * 0.44, size.height * 0.67)
      ..lineTo(size.width * 0.73, size.height * 0.36);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_Check old) => old.progress != progress;
}
