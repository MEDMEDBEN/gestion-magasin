import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/auth_models.dart';
import '../../features/auth/application/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/screen_state.dart';

/// Coquille desktop : navigation latérale permanente, dense.
/// Les modules apparaîtront ici au fur et à mesure des features P0.
class DesktopShell extends ConsumerWidget {
  const DesktopShell({super.key, required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingMutationsCountProvider);
    final rejected = ref.watch(rejectedMutationsProvider);

    return Scaffold(
      body: Row(
        children: [
          _Sidebar(user: user),
          const VerticalDivider(width: 1, color: AppColors.border),
          Expanded(
            child: Column(
              children: [
                _TopBar(
                  pendingCount: pending.value ?? 0,
                  rejectedCount: rejected.value?.length ?? 0,
                ),
                const Divider(height: 1, color: AppColors.border),
                const Expanded(
                  child: ScreenStateView(
                    status: ScreenStatus.empty,
                    message: 'Les modules arrivent avec les features P0.\n'
                        'La fondation (session, sync, thème) est en place.',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(20),
            child: Row(
              children: [
                // Clin d'œil « disjoncteur » de la sidebar (spec §30).
                Icon(Icons.electrical_services,
                    color: AppColors.accent, size: 22),
                SizedBox(width: 10),
                Text(
                  'Gestion magasin',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          const Spacer(),
          const Divider(height: 1, color: AppColors.border),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.fullName,
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
                Text(
                  user.roles.join(' · '),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () =>
                      ref.read(authControllerProvider.notifier).logout(),
                  icon: const Icon(Icons.logout, size: 16),
                  label: const Text('Déconnexion'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.pendingCount, required this.rejectedCount});

  final int pendingCount;
  final int rejectedCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          const Text('Accueil', style: TextStyle(fontSize: 16)),
          const Spacer(),
          // Indicateur de sync visible en permanence (docs/context.md).
          SyncIndicator(
            pendingCount: pendingCount,
            rejectedCount: rejectedCount,
          ),
        ],
      ),
    );
  }
}
