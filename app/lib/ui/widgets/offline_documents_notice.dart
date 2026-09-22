import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../theme/ampere_colors.dart';
import 'screen_state.dart';

/// Dit qu'une liste vient de la COPIE LOCALE et de quand elle date (P1 n°14).
///
/// Il suit la LISTE AFFICHÉE, pas l'état du réseau : le réseau peut revenir
/// alors que l'écran montre encore la copie.
class OfflineDocumentsNotice extends StatelessWidget {
  const OfflineDocumentsNotice({
    super.key,
    required this.cachedAt,
    this.actionsQueue = true,
  });

  /// Date de la copie ; `null` = liste fraîche, rien à dire.
  final DateTime? cachedAt;

  /// Les actions de cet écran partent-elles dans la file ? (Le comptage
  /// d'inventaire, lui, exige la connexion — docs/context.md §9.)
  final bool actionsQueue;

  @override
  Widget build(BuildContext context) {
    final at = cachedAt;
    if (at == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AmpereInlineAlert(
        tone: StatusTone.warn,
        message:
            'Hors ligne : liste du ${formatDateTime(at)}. '
            '${actionsQueue ? 'Vos actions partiront à la synchronisation.' : 'Le comptage, lui, exige la connexion.'}',
      ),
    );
  }
}
