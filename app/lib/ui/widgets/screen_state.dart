import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Les 6 états que CHAQUE écran important doit savoir rendre
/// (docs/spec-fonctionnelle.md §30, CONVENTIONS.md § États d'écran).
///
/// `syncPending` est distinct de `success` : une opération non confirmée par le
/// serveur ne doit JAMAIS s'afficher comme définitive (docs/context.md §6).
enum ScreenStatus { loading, empty, error, success, offline, syncPending }

/// Vue générique pour les états non-`success`.
class ScreenStateView extends StatelessWidget {
  const ScreenStateView({
    super.key,
    required this.status,
    this.message,
    this.onRetry,
  });

  final ScreenStatus status;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (status == ScreenStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final (icon, color, defaultMessage) = switch (status) {
      ScreenStatus.empty => (
          Icons.inbox_outlined,
          AppColors.textSecondary,
          'Aucune donnée',
        ),
      ScreenStatus.error => (
          Icons.error_outline,
          AppColors.danger,
          'Une erreur est survenue',
        ),
      ScreenStatus.offline => (
          Icons.cloud_off_outlined,
          AppColors.warning,
          'Hors connexion — les données affichées peuvent être périmées',
        ),
      ScreenStatus.syncPending => (
          Icons.sync,
          AppColors.warning,
          'En attente de synchronisation',
        ),
      _ => (Icons.check_circle_outline, AppColors.success, 'Terminé'),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 12),
            Text(
              message ?? defaultMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('Réessayer'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Indicateur de synchronisation, visible en permanence (docs/context.md § Mobile).
/// `✓ Synchronisé` · `⟳ N en attente` · `⚠ N échouée(s)`.
class SyncIndicator extends StatelessWidget {
  const SyncIndicator({
    super.key,
    required this.pendingCount,
    this.rejectedCount = 0,
    this.isOffline = false,
  });

  final int pendingCount;
  final int rejectedCount;
  final bool isOffline;

  @override
  Widget build(BuildContext context) {
    // Un rejet exige une action de l'utilisateur : il prime sur le reste.
    final (icon, color, label) = rejectedCount > 0
        ? (Icons.warning_amber_rounded, AppColors.danger,
            '$rejectedCount échouée${rejectedCount > 1 ? 's' : ''}')
        : isOffline
            ? (Icons.cloud_off_outlined, AppColors.warning, 'Hors ligne')
            : pendingCount > 0
                ? (Icons.sync, AppColors.warning, '$pendingCount en attente')
                : (Icons.check_circle_outline, AppColors.success, 'Synchronisé');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }
}
