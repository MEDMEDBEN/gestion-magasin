import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';

/// Une action dans un panneau de choix (demande MEDMEDBEN du 2026-10-28 :
/// des actions qu'on COMPREND d'un coup d'œil). Icône dans une pastille à la
/// couleur de ce qu'elle fait (vert = avancer, rouge = annuler/supprimer,
/// bleu = information), libellé net, flèche. L'action conseillée (`primary`)
/// est mise en avant. Remplace `SimpleDialogOption` : même `onPressed`.
class ActionOption extends StatelessWidget {
  const ActionOption({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.child,
    this.tone = StatusTone.neutral,
    this.primary = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;

  /// Le libellé (un `Text`).
  final Widget child;
  final StatusTone tone;

  /// L'étape suivante conseillée : fond teinté, libellé appuyé.
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final danger = tone == StatusTone.error;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: primary ? colors.accentBg : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: primary ? colors.accent.withValues(alpha: 0.5) : colors.line,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: tone.background(colors),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 16, color: tone.foreground(colors)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: AmpereType.bodyStrong.copyWith(
                      fontSize: 14,
                      color: danger ? colors.error : colors.ink,
                      fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
                    ),
                    child: child,
                  ),
                ),
                Icon(LucideIcons.chevronRight, size: 16, color: colors.ink3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
