import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import 'feedback_burst.dart';

/// Plus de messages qui montent du bas (demande MEDMEDBEN du 2026-10-29) :
/// tout `showSnackBar` de l'application devient un EFFET en haut de l'écran,
/// adapté à l'action — ton (réussi / refusé / en attente) et icône (caisse,
/// impression, suppression, réception…) déduits du message, animation propre
/// à chaque ton (rebond, tremblement, rotation), barre du temps restant.
///
/// Posé une fois au-dessus des écrans (`main.dart`) : les 40+ appels
/// existants n'ont pas à changer. Le bouton d'une notification (« Imprimer le
/// bon ») est gardé ; « Fermer » est inutile, l'effet part seul.
class FeedbackMessenger extends ScaffoldMessenger {
  const FeedbackMessenger({super.key, required super.child});

  @override
  ScaffoldMessengerState createState() => _FeedbackMessengerState();
}

class _FeedbackMessengerState extends ScaffoldMessengerState {
  _Toast? _toast;
  int _serial = 0;

  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar, {
    AnimationStyle? snackBarAnimationStyle,
  }) {
    final message = _textOf(snackBar.content);
    // La grande pastille vient de confirmer la même action : pas de doublon.
    final justBurst =
        lastFeedbackBurst != null &&
        DateTime.now().difference(lastFeedbackBurst!) <
            const Duration(milliseconds: 1500);
    final action = snackBar.action;
    final useful = action != null && action.label != 'Fermer';
    if (!justBurst || useful) {
      setState(() {
        _toast = _Toast(
          key: ValueKey(++_serial),
          message: message ?? '',
          content: message == null ? snackBar.content : null,
          actionLabel: useful ? action.label : null,
          onAction: useful ? action.onPressed : null,
          onDone: () {
            if (mounted) setState(() => _toast = null);
          },
        );
      });
    }
    // Le contrat de `showSnackBar` est tenu par une barre invisible et
    // immédiate : les appelants (`.closed`, `hideCurrentSnackBar`) marchent.
    return super.showSnackBar(
      const SnackBar(
        content: SizedBox.shrink(),
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        behavior: SnackBarBehavior.floating,
        width: 1,
        duration: Duration(milliseconds: 1),
      ),
      snackBarAnimationStyle: AnimationStyle.noAnimation,
    );
  }

  static String? _textOf(Widget content) => switch (content) {
    Text(:final data?) => data,
    Text(:final textSpan?) => textSpan.toPlainText(),
    _ => null,
  };

  @override
  Widget build(BuildContext context) =>
      Stack(children: [super.build(context), ?_toast]);
}

/// Ton d'un message.
enum _Tone { success, error, pending }

/// Ton et icône déduits du message : chaque action a SA réaction.
(_Tone, IconData) _classify(String message) {
  final m = message.toLowerCase();
  bool has(List<String> words) => words.any(m.contains);
  final tone =
      has([
        'impossible',
        'refus',
        'erreur',
        'invalide',
        'introuvable',
        'échou',
        'interdit',
        'pas assez',
        'insuffisant',
        'dépasse',
        'obligatoire',
        'incorrect',
        'illisible',
        'déjà',
        'aucun',
        'aucune',
        'trop',
        'ouvrez',
        'n’a pas',
        'vérifiez',
      ])
      ? _Tone.error
      : has(['hors ligne', 'attente', 'synchronis', 'lecture', 'en cours'])
      ? _Tone.pending
      : _Tone.success;
  final icon = has(['caisse'])
      ? (has(['clôtur', 'ferm']) ? LucideIcons.archive : LucideIcons.wallet)
      : has(['imprim', 'impression'])
      ? LucideIcons.printer
      : has(['supprim', 'retiré', 'désactiv'])
      ? LucideIcons.trash2
      : has(['copié'])
      ? LucideIcons.copy
      : has(['envoy'])
      ? LucideIcons.send
      : has(['mot de passe'])
      ? LucideIcons.keyRound
      : has(['transfert'])
      ? LucideIcons.arrowLeftRight
      : has(['réception', 'réceptionn', 'livraison'])
      ? LucideIcons.packageCheck
      : has(['commande'])
      ? LucideIcons.clipboardList
      : has(['export'])
      ? LucideIcons.download
      : has(['import'])
      ? LucideIcons.upload
      : has(['produit', 'catalogue', 'code-barres'])
      ? LucideIcons.packagePlus
      : has(['client', 'confrère', 'fournisseur'])
      ? LucideIcons.userCheck
      : has(['tâche'])
      ? LucideIcons.listChecks
      : has(['message'])
      ? LucideIcons.messageSquare
      : has(['stock', 'perte', 'inventaire'])
      ? LucideIcons.boxes
      : switch (tone) {
          _Tone.success => LucideIcons.circleCheck,
          _Tone.error => LucideIcons.circleX,
          _Tone.pending => LucideIcons.clock,
        };
  return (tone, icon);
}

class _Toast extends StatefulWidget {
  const _Toast({
    super.key,
    required this.message,
    required this.onDone,
    this.content,
    this.actionLabel,
    this.onAction,
  });

  final String message;

  /// Contenu non textuel (rare) : affiché tel quel.
  final Widget? content;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDone;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  // Entrée 0,45 s, tenue (2,6 s ; 5,5 s avec un bouton), sortie 0,3 s.
  late final Duration _hold = widget.actionLabel == null
      ? const Duration(milliseconds: 2600)
      : const Duration(milliseconds: 5500);
  late final AnimationController _c =
      AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 750) + _hold,
        )
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) widget.onDone();
        })
        ..forward();

  double get _inEnd => 450 / _c.duration!.inMilliseconds;
  double get _outStart => 1 - 300 / _c.duration!.inMilliseconds;

  double _seg(double a, double b, [Curve curve = Curves.easeOut]) =>
      curve.transform(((_c.value - a) / (b - a)).clamp(0.0, 1.0));

  /// Fermer tout de suite : on joue la sortie depuis là où l'on en est.
  void _close() {
    if (_c.value < _outStart) _c.forward(from: _outStart);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final (tone, icon) = _classify(widget.message);
    final color = switch (tone) {
      _Tone.success => colors.ok,
      _Tone.error => colors.error,
      _Tone.pending => colors.warn,
    };
    return Positioned(
      top: 84,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final enter = _seg(0, _inEnd, Curves.easeOutBack);
            final leave = _seg(_outStart, 1, Curves.easeIn);
            final pop = _seg(0.05 * _inEnd, _inEnd, Curves.elasticOut);
            // Réaction propre au ton.
            final shake = tone == _Tone.error
                ? math.sin(_seg(0, _inEnd * 2.2, Curves.linear) * math.pi * 5) *
                      7 *
                      (1 - _seg(0, _inEnd * 2.2))
                : 0.0;
            final spin = tone == _Tone.pending
                ? _seg(0, _inEnd * 3, Curves.easeOutCubic) * math.pi * 2
                : 0.0;
            final remaining = 1 - _seg(_inEnd, _outStart, Curves.linear);
            return Opacity(
              opacity: (enter * (1 - leave)).clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(shake, -26 * (1 - enter) - 16 * leave),
                child: Transform.scale(
                  scale: 0.92 + 0.08 * enter,
                  child: _card(colors, color, icon, tone, pop, spin, remaining),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _card(
    AmpereColors colors,
    Color color,
    IconData icon,
    _Tone tone,
    double pop,
    double spin,
    double remaining,
  ) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, minWidth: 280),
      child: Material(
        type: MaterialType.transparency,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          // Pas de flou d'arrière-plan : sous un fondu (Opacity), il ne se
          // dessine pas. Un fond presque opaque fait le même effet.
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: 0.97),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: color.withValues(alpha: 0.45)),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.25),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Badge : il « réagit » (rebond, tremblement, tour).
                      Transform.scale(
                        scale: 0.6 + 0.4 * pop,
                        child: Transform.rotate(
                          angle: spin,
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: color,
                              boxShadow: [
                                BoxShadow(
                                  color: color.withValues(alpha: 0.45),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                            child: Icon(icon, size: 17, color: Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child:
                            widget.content ??
                            Text(
                              widget.message,
                              style: AmpereType.bodyStrong.copyWith(
                                color: colors.ink,
                                fontSize: 14,
                              ),
                            ),
                      ),
                      if (widget.actionLabel case final label?) ...[
                        const SizedBox(width: 10),
                        TextButton(
                          onPressed: () {
                            widget.onAction?.call();
                            _close();
                          },
                          child: Text(label),
                        ),
                      ],
                      // Sans infobulle : l'effet vit au-dessus du
                      // navigateur, hors de tout calque d'infobulles.
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: _close,
                        icon: Icon(LucideIcons.x, size: 15, color: colors.ink3),
                      ),
                    ],
                  ),
                ),
                // Le temps qui reste, en fine barre.
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: remaining,
                    child: Container(height: 3, color: color),
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
