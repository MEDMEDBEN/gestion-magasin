import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../data/models/user_models.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/users_controller.dart';
import 'user_form_sheet.dart';

/// Gestion des comptes — **ADMIN uniquement** (`docs/permissions.md` §Administration).
/// Le backend refuse de toute façon : l'UI ne fait que masquer ce qui serait rejeté.
///
/// Mise en page adaptative : liste dense sur desktop, lignes tactiles ≥ 56 sur
/// mobile (AMPÈRE §9 — aucun tableau sur mobile).
class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openCreate() async {
    final created = await showUserFormSheet(context, ref);
    if (created != null && mounted) {
      _showSnack(
        'Compte créé pour ${created.fullName}. '
        'Il devra changer son mot de passe à la première connexion.',
      );
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final usersAsync = ref.watch(usersControllerProvider);
    final searchTerm = ref.watch(userSearchProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Utilisateurs'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _openCreate,
              icon: const Icon(LucideIcons.plus, size: 17),
              label: const Text('Nouveau'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _search,
              style: AmpereType.input.copyWith(color: colors.ink),
              decoration: InputDecoration(
                hintText: 'Rechercher un nom, un email, un téléphone',
                prefixIcon: const Icon(LucideIcons.search, size: 17),
                suffixIcon: searchTerm.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Effacer',
                        icon: const Icon(LucideIcons.x, size: 17),
                        onPressed: () {
                          _search.clear();
                          ref.read(userSearchProvider.notifier).clear();
                        },
                      ),
              ),
              onSubmitted: (value) =>
                  ref.read(userSearchProvider.notifier).set(value),
            ),
          ),
          Expanded(
            child: usersAsync.when(
              loading: () => const AmpereSkeletonList(rows: 6),
              error: (error, _) => ScreenStateView(
                status: error is ApiException && error.isOffline
                    ? ScreenStatus.offline
                    : ScreenStatus.error,
                message: error is ApiException ? error.userMessage : null,
                onRetry: () =>
                    ref.read(usersControllerProvider.notifier).refresh(),
              ),
              data: (page) {
                if (page.data.isEmpty) {
                  // « Vide » et « aucun résultat » sont deux états distincts (§8).
                  return searchTerm.isEmpty
                      ? ScreenStateView(
                          status: ScreenStatus.empty,
                          title: 'Aucun utilisateur',
                          message:
                              'Créez le premier compte de votre équipe.',
                          action: FilledButton.icon(
                            onPressed: _openCreate,
                            icon: const Icon(LucideIcons.plus, size: 17),
                            label: const Text('Nouvel utilisateur'),
                          ),
                        )
                      : ScreenStateView(
                          status: ScreenStatus.noResults,
                          searchTerm: searchTerm,
                        );
                }

                return RefreshIndicator(
                  onRefresh: () =>
                      ref.read(usersControllerProvider.notifier).refresh(),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: page.data.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      if (index == page.data.length) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            '${page.meta.total} compte'
                            '${page.meta.total > 1 ? 's' : ''}',
                            style: AmpereType.meta.copyWith(color: colors.ink3),
                          ),
                        );
                      }
                      return _UserRow(
                        user: page.data[index],
                        onChanged: _showSnack,
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Une ligne de liste (§7) : pastille + identité + badges + menu d'actions.
class _UserRow extends ConsumerWidget {
  const _UserRow({required this.user, required this.onChanged});

  final ManagedUser user;
  final void Function(String message) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);

    return Container(
      constraints: const BoxConstraints(minHeight: AmpereGeometry.listRowMin),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line, width: 1),
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
                  user.fullName,
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
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final code in user.roles)
                      AmpereBadge(
                        label: AppRoleCode.fromCode(code)?.label ?? code,
                        tone: StatusTone.info,
                      ),
                    // Le statut porte TOUJOURS un libellé, jamais la couleur
                    // seule (§12.4).
                    if (!user.isActive)
                      const AmpereBadge(
                        label: 'Désactivé',
                        tone: StatusTone.neutral,
                        icon: LucideIcons.ban,
                      ),
                    if (user.mustChangePassword)
                      const AmpereBadge(
                        label: 'Mot de passe temporaire',
                        tone: StatusTone.warn,
                        icon: LucideIcons.keyRound,
                      ),
                  ],
                ),
              ],
            ),
          ),
          _UserActionsMenu(user: user, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _UserActionsMenu extends ConsumerWidget {
  const _UserActionsMenu({required this.user, required this.onChanged});

  final ManagedUser user;
  final void Function(String message) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Actions',
      icon: const Icon(LucideIcons.ellipsisVertical, size: 19),
      onSelected: (action) => _run(context, ref, action),
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'edit',
          child: _MenuRow(icon: LucideIcons.pencil, label: 'Modifier'),
        ),
        PopupMenuItem(
          value: 'toggle',
          child: _MenuRow(
            icon: user.isActive ? LucideIcons.ban : LucideIcons.circleCheck,
            label: user.isActive ? 'Désactiver' : 'Réactiver',
          ),
        ),
        const PopupMenuItem(
          value: 'reset',
          child: _MenuRow(
            icon: LucideIcons.keyRound,
            label: 'Réinitialiser le mot de passe',
          ),
        ),
        const PopupMenuItem(
          value: 'revoke',
          child: _MenuRow(
            icon: LucideIcons.smartphone,
            label: 'Révoquer les sessions',
          ),
        ),
      ],
    );
  }

  Future<void> _run(BuildContext context, WidgetRef ref, String action) async {
    final controller = ref.read(usersControllerProvider.notifier);
    try {
      switch (action) {
        case 'edit':
          final updated = await showUserFormSheet(context, ref, existing: user);
          if (updated != null) onChanged('${updated.fullName} mis à jour.');

        case 'toggle':
          // Désactiver coupe l'accès : action destructive, on confirme (§12.7).
          if (user.isActive) {
            final ok = await _confirm(
              context,
              title: 'Désactiver ${user.fullName} ?',
              body: 'Le compte ne pourra plus se connecter et ses sessions '
                  'en cours seront fermées.',
              confirmLabel: 'Désactiver',
            );
            if (!ok) return;
          }
          await controller.setActive(user.id, isActive: !user.isActive);
          onChanged(
            user.isActive
                ? '${user.fullName} désactivé.'
                : '${user.fullName} réactivé.',
          );

        case 'reset':
          if (!context.mounted) return;
          final password = await _askTemporaryPassword(context);
          if (password == null) return;
          await controller.resetPassword(user.id, password);
          onChanged(
            'Mot de passe réinitialisé. Communiquez-le à ${user.fullName} : '
            'il devra le changer à la connexion.',
          );

        case 'revoke':
          final ok = await _confirm(
            context,
            title: 'Révoquer les sessions ?',
            body: '${user.fullName} devra se reconnecter sur tous ses appareils.',
            confirmLabel: 'Révoquer',
          );
          if (!ok) return;
          final count = await controller.revokeSessions(user.id);
          onChanged(
            count == 0
                ? 'Aucune session active à révoquer.'
                : '$count session${count > 1 ? 's' : ''} révoquée'
                    '${count > 1 ? 's' : ''}.',
          );
      }
    } on ApiException catch (error) {
      onChanged(error.userMessage);
    }
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    if (!context.mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<String?> _askTemporaryPassword(BuildContext context) {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouveau mot de passe temporaire'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${user.fullName} devra le changer à sa prochaine connexion.',
                style: AmpereType.body.copyWith(
                  color: AmpereColors.of(context).ink2,
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  helperText: '8 caractères minimum',
                ),
                validator: (v) =>
                    (v == null || v.length < 8) ? 'Au moins 8 caractères' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(context).pop(controller.text);
              }
            },
            child: const Text('Réinitialiser'),
          ),
        ],
      ),
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
      children: [
        Icon(icon, size: 17, color: AmpereColors.of(context).ink2),
        const SizedBox(width: 10),
        Text(label),
      ],
    );
  }
}
