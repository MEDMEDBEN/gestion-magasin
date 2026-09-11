import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/users_controller.dart';
import '../data/user_models.dart';

/// Badges de rôles d'un compte — le rôle est traduit, jamais affiché sous son
/// code technique.
class UserRoleBadges extends StatelessWidget {
  const UserRoleBadges({super.key, required this.user});

  final ManagedUser user;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final code in user.roles)
          AmpereBadge(
            label: AppRoleCode.fromCode(code)?.label ?? code,
            tone: StatusTone.info,
          ),
        if (user.extraPermissions.isNotEmpty)
          AmpereBadge(
            label: '+${user.extraPermissions.length} permission'
                '${user.extraPermissions.length > 1 ? 's' : ''}',
            tone: StatusTone.neutral,
          ),
      ],
    );
  }
}

/// Statut d'un compte — TOUJOURS un libellé, jamais la couleur seule (§12.4).
class UserStatusBadges extends StatelessWidget {
  const UserStatusBadges({super.key, required this.user, this.showActive = false});

  final ManagedUser user;

  /// Le tableau desktop affiche aussi « Actif » (colonne Statut) ; la liste
  /// mobile ne signale que ce qui sort de l'ordinaire.
  final bool showActive;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (!user.isActive)
          const AmpereBadge(
            label: 'Désactivé',
            tone: StatusTone.neutral,
            icon: LucideIcons.ban,
          )
        else if (showActive)
          const AmpereBadge(label: 'Actif', tone: StatusTone.ok),
        if (user.mustChangePassword)
          const AmpereBadge(
            label: 'Mot de passe temporaire',
            tone: StatusTone.warn,
            icon: LucideIcons.keyRound,
          ),
      ],
    );
  }
}

/// Pied de liste : total réel côté serveur et chargement de la suite.
class UsersListFooter extends StatelessWidget {
  const UsersListFooter({
    super.key,
    required this.state,
    required this.onLoadMore,
  });

  final UsersListState state;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final shown = state.items.length;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 14,
        runSpacing: 8,
        children: [
          Text(
            state.hasMore
                ? '$shown affichés sur ${state.total} comptes'
                : '${state.total} compte${state.total > 1 ? 's' : ''}',
            style: AmpereType.meta.copyWith(
              color: colors.ink3,
              fontFeatures: AmpereType.tabular,
            ),
          ),
          if (state.hasMore)
            OutlinedButton.icon(
              onPressed: state.isLoadingMore ? null : onLoadMore,
              icon: const Icon(LucideIcons.chevronsDown, size: 17),
              label: Text(state.isLoadingMore ? 'Chargement…' : 'Afficher plus'),
            ),
        ],
      ),
    );
  }
}
