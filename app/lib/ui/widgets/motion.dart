import 'package:flutter/material.dart';

/// Mouvements partagés de l'application (demande MEDMEDBEN du 2026-10-29 :
/// « pas un clic brut — on voit la sélection glisser vers le bouton choisi »).

/// Courbe « ressort » douce, façon iOS : un léger dépassement puis l'arrêt.
const Curve springCurve = Cubic(0.34, 1.36, 0.64, 1);

/// Une rangée d'éléments dont le repère de sélection (`indicator`) GLISSE
/// d'un élément à l'autre au lieu de sauter. Les positions sont mesurées
/// après la mise en page : les éléments peuvent avoir des largeurs inégales.
class SlidingSelection extends StatefulWidget {
  const SlidingSelection({
    super.key,
    required this.selected,
    required this.children,
    required this.indicator,
    this.expand = false,
    this.duration = const Duration(milliseconds: 420),
  });

  /// Index choisi ; `null` : aucun repère.
  final int? selected;
  final List<Widget> children;

  /// Ce qui glisse (pastille, soulignement…) ; il remplit l'élément choisi.
  final Widget indicator;

  /// Éléments de même largeur, sur toute la place (barre du bas).
  final bool expand;
  final Duration duration;

  @override
  State<SlidingSelection> createState() => _SlidingSelectionState();
}

class _SlidingSelectionState extends State<SlidingSelection> {
  final _stack = GlobalKey();
  List<GlobalKey> _keys = [];
  Rect? _rect;

  /// Première mesure : le repère se pose, il ne vole pas depuis le coin.
  bool _placed = false;

  void _measure() {
    if (!mounted) return;
    final i = widget.selected;
    final stack = _stack.currentContext?.findRenderObject() as RenderBox?;
    final box = i == null || i >= _keys.length
        ? null
        : _keys[i].currentContext?.findRenderObject() as RenderBox?;
    final rect = stack == null || box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero, ancestor: stack) & box.size;
    if (rect != _rect) {
      setState(() => _rect = rect);
    } else if (!_placed && rect != null) {
      setState(() => _placed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_keys.length != widget.children.length) {
      _keys = [for (final _ in widget.children) GlobalKey()];
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final reduce = MediaQuery.disableAnimationsOf(context);
    final rect = _rect;
    return Stack(
      key: _stack,
      children: [
        if (rect != null)
          AnimatedPositioned(
            duration: _placed && !reduce ? widget.duration : Duration.zero,
            curve: springCurve,
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            child: IgnorePointer(child: widget.indicator),
          ),
        Row(
          mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (final (i, c) in widget.children.indexed)
              widget.expand
                  ? Expanded(
                      child: KeyedSubtree(key: _keys[i], child: c),
                    )
                  : KeyedSubtree(key: _keys[i], child: c),
          ],
        ),
      ],
    );
  }
}

/// Entrée en douceur : fondu et légère montée à l'apparition (`delay` pour
/// une cascade). Rien si l'appareil demande moins d'animations.
class Appear extends StatefulWidget {
  const Appear({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  State<Appear> createState() => _AppearState();
}

class _AppearState extends State<Appear> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320) + widget.delay,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = 1;
    } else if (!_c.isAnimating && _c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = widget.delay.inMilliseconds / _c.duration!.inMilliseconds;
    final t = CurvedAnimation(
      parent: _c,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: t,
      child: AnimatedBuilder(
        animation: t,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, 10 * (1 - t.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
