import 'package:flutter/material.dart';

import '../../../../core/dates.dart';
import '../../../../ui/theme/ampere_colors.dart';
import '../../../../ui/theme/ampere_typography.dart';
import '../../../../ui/widgets/ampere_controls.dart';
import '../../application/users_controller.dart';
import '../../data/user_models.dart';
import '../user_actions.dart';
import '../user_badges.dart';

/// Tableau desktop dense (AMPÈRE §6) : en-tête en capitales, séparateurs
/// `line-soft`, survol accent 8 %, ligne entière cliquable (édition), actions
/// 28 px à droite, dates en chiffres tabulaires alignées à droite. En dessous de
/// sa largeur utile, il défile horizontalement (§9) — jamais de colonne
/// hors écran sans défilement.
class UsersTable extends StatelessWidget {
  const UsersTable({
    super.key,
    required this.state,
    required this.currentUserId,
    required this.onLoadMore,
    required this.onEdit,
    required this.onMessage,
  });

  final UsersListState state;
  final String? currentUserId;
  final VoidCallback onLoadMore;
  final void Function(ManagedUser user) onEdit;
  final void Function(String message) onMessage;

  static const double _minWidth = 860;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth < _minWidth ? _minWidth : constraints.maxWidth;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AmpereGeometry.screenMarginDesktop,
            0,
            AmpereGeometry.screenMarginDesktop,
            AmpereGeometry.screenMarginDesktop,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: width - AmpereGeometry.screenMarginDesktop * 2,
                    child: Column(
                      children: [
                        const _HeaderRow(),
                        Divider(height: 1, color: colors.line),
                        for (var i = 0; i < state.items.length; i++) ...[
                          _UserTableRow(
                            user: state.items[i],
                            isSelf: state.items[i].id == currentUserId,
                            currentUserId: currentUserId,
                            onTap: () => onEdit(state.items[i]),
                            onMessage: onMessage,
                          ),
                          // Dernière ligne sans séparateur (§4).
                          if (i < state.items.length - 1)
                            Divider(height: 1, color: colors.lineSoft),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              UsersListFooter(state: state, onLoadMore: onLoadMore),
            ],
          ),
        );
      },
    );
  }
}

/// Répartition des colonnes, partagée par l'en-tête et les lignes.
class _Columns {
  static const account = 5;
  static const roles = 4;
  static const status = 3;
  static const lastLogin = 3;
  static const actionsWidth = 48.0;
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = AmpereType.label.copyWith(color: AmpereColors.of(context).ink3);
    Widget cell(String text, int flex, {bool end = false}) => Expanded(
          flex: flex,
          child: Text(
            text.toUpperCase(),
            textAlign: end ? TextAlign.end : TextAlign.start,
            style: style,
          ),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          cell('Compte', _Columns.account),
          cell('Rôles', _Columns.roles),
          cell('Statut', _Columns.status),
          cell('Dernière connexion', _Columns.lastLogin, end: true),
          const SizedBox(width: _Columns.actionsWidth),
        ],
      ),
    );
  }
}

class _UserTableRow extends StatelessWidget {
  const _UserTableRow({
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
    final lastLogin = user.lastLoginAt;

    return AmpereTappable(
      onTap: onTap,
      borderRadius: 0,
      child: Padding(
        // Densité « normal » (§6) : py 10, texte 13,5.
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Expanded(
              flex: _Columns.account,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isSelf ? '${user.fullName} (vous)' : user.fullName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user.loginIdentifier,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.mono.copyWith(color: colors.ink3),
                  ),
                ],
              ),
            ),
            Expanded(flex: _Columns.roles, child: UserRoleBadges(user: user)),
            Expanded(
              flex: _Columns.status,
              child: UserStatusBadges(user: user, showActive: true),
            ),
            Expanded(
              flex: _Columns.lastLogin,
              child: Text(
                lastLogin == null ? 'Jamais' : formatDateTime(lastLogin),
                textAlign: TextAlign.end,
                style: AmpereType.bodyDesktop.copyWith(
                  color: lastLogin == null ? colors.ink3 : colors.ink2,
                  fontFeatures: AmpereType.tabular,
                ),
              ),
            ),
            SizedBox(
              width: _Columns.actionsWidth,
              child: Align(
                alignment: Alignment.centerRight,
                child: UserActionsMenu(
                  user: user,
                  isSelf: isSelf,
                  currentUserId: currentUserId,
                  onMessage: onMessage,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
