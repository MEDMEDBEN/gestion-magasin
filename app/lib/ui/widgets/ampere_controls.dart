import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/ampere_colors.dart';
import '../theme/app_theme.dart';
import '../theme/ampere_typography.dart';

/// Bouton **Danger** (AMPÈRE §6) : transparent, bordure et texte `error`,
/// JAMAIS rempli. Réservé à la confirmation d'une action destructive.
class AmpereDangerButton extends StatelessWidget {
  const AmpereDangerButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
  });

  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final style = OutlinedButton.styleFrom(
      foregroundColor: colors.error,
      backgroundColor: Colors.transparent,
    ).copyWith(
      // Bordure `error` au repos, anneau de focus `accent` au clavier.
      side: AppTheme.focusSide(
        colors,
        idle: BorderSide(color: colors.error, width: AmpereGeometry.borderWidth),
      ),
    );
    final text = Text(label);
    return icon == null
        ? OutlinedButton(onPressed: onPressed, style: style, child: text)
        : OutlinedButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon, size: 17),
            label: text,
          );
  }
}

/// Zone cliquable (ligne de liste, élément de navigation, option à cocher) dont
/// le focus clavier est TOUJOURS visible : contour 2 px `accent` (§6, §12.10).
/// Un `InkWell` nu n'affiche qu'un voile à peine perceptible au clavier.
class AmpereTappable extends StatefulWidget {
  const AmpereTappable({
    super.key,
    required this.onTap,
    required this.child,
    required this.borderRadius,
    this.color = Colors.transparent,
  });

  final VoidCallback? onTap;
  final Widget child;
  final double borderRadius;
  final Color color;

  @override
  State<AmpereTappable> createState() => _AmpereTappableState();
}

class _AmpereTappableState extends State<AmpereTappable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final radius = BorderRadius.circular(widget.borderRadius);

    return Material(
      color: widget.color,
      borderRadius: radius,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: radius,
        hoverColor: colors.accent.withValues(alpha: 0.08),
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: Container(
          foregroundDecoration: _focused
              ? BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: colors.accent, width: 2),
                )
              : null,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Dialogue de confirmation d'une action DESTRUCTIVE (§6 : un dialogue est
/// réservé à une décision financière ou destructive ; §12.7 : jamais pour une
/// action ordinaire). Le bouton de confirmation est en style Danger.
/// Renvoie `true` si l'utilisateur confirme.
Future<bool> showAmpereConfirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierColor: AmpereColors.of(context).scrim,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Text(body),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        AmpereDangerButton(
          onPressed: () => Navigator.of(context).pop(true),
          label: confirmLabel,
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Panneau latéral droit (desktop, §6) : saisie longue sans quitter la liste.
/// Sur mobile, une saisie longue se fait en plein écran — jamais dans une
/// feuille modale basse (§7). `Échap` et un clic sur la scène le ferment.
Future<T?> showAmpereSidePanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double width = 440,
}) {
  final colors = AmpereColors.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fermer',
    barrierColor: colors.scrim,
    transitionDuration: AmpereGeometry.sheet,
    pageBuilder: (context, _, _) {
      final panelWidth = math.min(width, MediaQuery.sizeOf(context).width);
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: panelWidth,
          height: double.infinity,
          child: Material(
            color: colors.surface,
            // La scène assombrie (`scrim`) et la bordure gauche détachent déjà le
            // panneau : une ombre Material dessinerait ici une bande noire dure,
            // à l'opposé de l'élévation douce voulue par §4.
            shape: Border(left: BorderSide(color: colors.line)),
            child: SafeArea(child: builder(context)),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, _, child) {
      // Mouvement §4 : entrée 200 ms, translation courte — et un simple fondu si
      // l'OS demande de réduire les animations.
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
      if (MediaQuery.disableAnimationsOf(context)) {
        return FadeTransition(opacity: curved, child: child);
      }
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0.06, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
