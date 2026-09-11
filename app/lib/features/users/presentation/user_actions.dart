import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/users_controller.dart';
import '../data/user_models.dart';
import 'user_form.dart';

enum _UserAction { edit, toggle, reset, revoke }

/// Menu d'actions d'un compte (ligne de liste mobile, cellule de tableau
/// desktop). Sur SON propre compte, l'admin n'a que « Modifier » : son
/// activation passe par un autre administrateur, et son mot de passe ou ses
/// sessions se gèrent depuis « Mon profil ».
class UserActionsMenu extends ConsumerWidget {
  const UserActionsMenu({
    super.key,
    required this.user,
    required this.isSelf,
    required this.onMessage,
    this.currentUserId,
  });

  final ManagedUser user;
  final bool isSelf;
  final String? currentUserId;

  /// Retour à afficher (toast) après l'action.
  final void Function(String message) onMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_UserAction>(
      tooltip: 'Actions',
      icon: const Icon(LucideIcons.ellipsisVertical, size: 19),
      onSelected: (action) => _run(context, ref, action),
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: _UserAction.edit,
          child: _MenuRow(icon: LucideIcons.pencil, label: 'Modifier'),
        ),
        if (!isSelf) ...[
          PopupMenuItem(
            value: _UserAction.toggle,
            child: _MenuRow(
              icon: user.isActive ? LucideIcons.ban : LucideIcons.circleCheck,
              label: user.isActive ? 'Désactiver' : 'Réactiver',
            ),
          ),
          const PopupMenuItem(
            value: _UserAction.reset,
            child: _MenuRow(
              icon: LucideIcons.keyRound,
              label: 'Réinitialiser le mot de passe',
            ),
          ),
          const PopupMenuItem(
            value: _UserAction.revoke,
            child: _MenuRow(
              icon: LucideIcons.smartphone,
              label: 'Révoquer les sessions',
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _run(BuildContext context, WidgetRef ref, _UserAction action) async {
    final controller = ref.read(usersControllerProvider.notifier);
    try {
      switch (action) {
        case _UserAction.edit:
          final updated = await openUserForm(
            context,
            existing: user,
            currentUserId: currentUserId,
          );
          if (updated != null && updated != user) {
            onMessage('${updated.fullName} mis à jour.');
          }

        case _UserAction.toggle:
          // Désactiver coupe l'accès : action destructive, on confirme (§12.7).
          // Réactiver ne détruit rien : pas de dialogue.
          if (user.isActive) {
            final ok = await showAmpereConfirmDialog(
              context,
              title: 'Désactiver ${user.fullName} ?',
              body: 'Le compte ne pourra plus se connecter ni renouveler sa '
                  'session. Un accès déjà ouvert s’arrête au plus tard '
                  'sous 15 minutes.',
              confirmLabel: 'Désactiver',
            );
            if (!ok) return;
          }
          await controller.setActive(user.id, isActive: !user.isActive);
          onMessage(
            user.isActive
                ? '${user.fullName} désactivé.'
                : '${user.fullName} réactivé.',
          );

        case _UserAction.reset:
          final password = await showDialog<String>(
            context: context,
            barrierColor: AmpereColors.of(context).scrim,
            builder: (_) => _TemporaryPasswordDialog(fullName: user.fullName),
          );
          if (password == null) return;
          await controller.resetPassword(user.id, password);
          onMessage(
            'Mot de passe réinitialisé. Communiquez-le à ${user.fullName} : '
            'il devra le changer à la connexion.',
          );

        case _UserAction.revoke:
          final ok = await showAmpereConfirmDialog(
            context,
            title: 'Révoquer les sessions ?',
            body: '${user.fullName} devra se reconnecter sur tous ses '
                'appareils — au plus tard sous 15 minutes pour un accès '
                'déjà ouvert.',
            confirmLabel: 'Révoquer',
          );
          if (!ok) return;
          final count = await controller.revokeSessions(user.id);
          onMessage(
            count == 0
                ? 'Aucune session active à révoquer.'
                : '$count session${count > 1 ? 's' : ''} révoquée'
                    '${count > 1 ? 's' : ''}.',
          );
      }
    } on ApiException catch (error) {
      onMessage(error.userMessage);
    }
  }
}

/// Saisie du mot de passe temporaire. Réinitialiser coupe les sessions du
/// compte : décision destructive, d'où le dialogue (§6) et le bouton Danger.
/// `StatefulWidget` : le contrôleur de saisie est libéré à la fermeture.
class _TemporaryPasswordDialog extends StatefulWidget {
  const _TemporaryPasswordDialog({required this.fullName});

  final String fullName;

  @override
  State<_TemporaryPasswordDialog> createState() =>
      _TemporaryPasswordDialogState();
}

class _TemporaryPasswordDialogState extends State<_TemporaryPasswordDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return AlertDialog(
      title: const Text('Nouveau mot de passe temporaire'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.fullName} devra le changer à sa prochaine connexion. '
                'Ses sessions en cours seront fermées.',
                style: AmpereType.body.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: 14),
              const AmpereFieldLabel('Mot de passe temporaire'),
              TextFormField(
                controller: _controller,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 128,
                decoration: const InputDecoration(
                  helperText: '8 caractères minimum',
                  counterText: '',
                ),
                onFieldSubmitted: (_) => _confirm(),
                validator: (v) =>
                    (v == null || v.length < 8) ? 'Au moins 8 caractères' : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        AmpereDangerButton(onPressed: _confirm, label: 'Réinitialiser'),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: AmpereColors.of(context).ink2),
        const SizedBox(width: 10),
        // Flexible : au zoom texte 200 % (§12), le libellé passe à la ligne au
        // lieu de déborder du menu.
        Flexible(child: Text(label)),
      ],
    );
  }
}
