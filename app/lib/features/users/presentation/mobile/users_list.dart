import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../ui/theme/ampere_colors.dart';
import '../../../../ui/theme/ampere_typography.dart';
import '../../../../ui/widgets/ampere_controls.dart';
import '../../../../ui/widgets/screen_state.dart';
import '../../application/users_controller.dart';
import '../../data/user_models.dart';
import '../user_actions.dart';
import '../user_badges.dart';

/// Liste mobile (AMPÈRE §7, §9 : aucun tableau sur mobile) — lignes tactiles
/// ≥ 56, pastille + identité + badges + menu. Toucher une ligne l'édite.
class UsersList extends StatelessWidget {
  const UsersList({
    super.key,
    required this.state,
    required this.currentUserId,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onEdit,
    required this.onMessage,
  });

  final UsersListState state;
  final String? currentUserId;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;
  final void Function(ManagedUser user) onEdit;
  final void Function(String message) onMessage;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(
          AmpereGeometry.screenMarginMobile,
          0,
          AmpereGeometry.screenMarginMobile,
          24,
        ),
        itemCount: state.items.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index == state.items.length) {
            return UsersListFooter(state: state, onLoadMore: onLoadMore);
          }
          final user = state.items[index];
          return _UserRow(
            user: user,
            isSelf: user.id == currentUserId,
            currentUserId: currentUserId,
            onTap: () => onEdit(user),
            onMessage: onMessage,
          );
        },
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.user,
    required this.isSelf,
    required this.currentUserId,
    required this.onTap,
    required this.onMessage,
  });

  final ManagedUser user;
  final bool isSelf;
  final String? currentUserId;
  final VoidCallback onTap;
  final void Function(String message) onMessage;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return AmpereTappable(
      onTap: onTap,
      borderRadius: AmpereGeometry.cardRadiusMobile,
      color: colors.surface,
      child: Container(
        constraints: const BoxConstraints(minHeight: AmpereGeometry.listRowMin),
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          border: Border.all(
            color: colors.line,
            width: AmpereGeometry.borderWidth,
          ),
          borderRadius: BorderRadius.circular(AmpereGeometry.cardRadiusMobile),
        ),
        child: Row(
          children: [
            AmpereIconChip(
              icon: LucideIcons.user,
              tone: user.isActive ? StatusTone.info : StatusTone.neutral,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isSelf ? '${user.fullName} (vous)' : user.fullName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.rowTitle.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user.loginIdentifier,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.meta.copyWith(color: colors.ink3),
                  ),
                  const SizedBox(height: 8),
                  UserRoleBadges(user: user),
                  if (!user.isActive || user.mustChangePassword) ...[
                    const SizedBox(height: 6),
                    UserStatusBadges(user: user),
                  ],
                ],
              ),
            ),
            UserActionsMenu(
              user: user,
              isSelf: isSelf,
              currentUserId: currentUserId,
              onMessage: onMessage,
            ),
          ],
        ),
      ),
    );
  }
}
