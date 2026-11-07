import 'package:flutter/material.dart';

/// Mouvements partagés de l'application (demande MEDMEDBEN du 2026-10-29 :
/// « pas un clic brut — on voit la sélection glisser vers le bouton choisi »).

/// Courbe douce, façon iOS, SANS dépassement : un rebond sur un élément qui
/// bouge la page se lisait comme une vibration (2026-11-07).
const Curve springCurve = Cubic(0.22, 1, 0.36, 1);

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
    this.duration = const Duration(milliseconds: 300),
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
    // Au demi-pixel près : un arrondi de mise en page ne relance rien.
    final old = _rect;
    final moved =
        (rect == null) != (old == null) ||
        (rect != null &&
            old != null &&
            ((rect.left - old.left).abs() > 0.5 ||
                (rect.top - old.top).abs() > 0.5 ||
                (rect.width - old.width).abs() > 0.5 ||
                (rect.height - old.height).abs() > 0.5));
    if (moved) {
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

/// Vague d'apparitions en cours : seules les PREMIÈRES cartes d'un écran
/// s'animent. Les cartes construites ensuite — au défilement d'une longue
/// liste — s'affichent directement : animer chacune pendant qu'on fait défiler
/// coûtait cher et ralentissait le défilement (2026-11-07).
DateTime _waveStart = DateTime(0);
DateTime _lastMount = DateTime(0);
int _waveCount = 0;

bool _joinWave() {
  final now = DateTime.now();
  // Plus d'une seconde sans nouvelle carte : un nouvel écran commence.
  if (now.difference(_lastMount) > const Duration(seconds: 1)) {
    _waveStart = now;
    _waveCount = 0;
  }
  _lastMount = now;
  _waveCount++;
  return _waveCount <= 12 &&
      now.difference(_waveStart) < const Duration(milliseconds: 600);
}

class _AppearState extends State<Appear> with SingleTickerProviderStateMixin {
  /// Créés seulement si la carte s'anime : une carte affichée directement
  /// (hors vague, ou animations réduites) n'a ni contrôleur ni ticker.
  AnimationController? _c;
  Animation<double>? _t;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context) || !_joinWave()) return;
    final c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320) + widget.delay,
    );
    _c = c;
    _t = CurvedAnimation(
      parent: c,
      curve: Interval(
        widget.delay.inMilliseconds / c.duration!.inMilliseconds,
        1,
        curve: Curves.easeOutCubic,
      ),
    );
    c.forward().whenCompleteOrCancel(() {
      // Animation finie : la carte est dessinée telle quelle, sans couche de
      // transparence ni transformation.
      if (mounted) setState(() => _t = null);
    });
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    if (t == null) return widget.child;
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
