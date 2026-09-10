import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/auth_models.dart';
import '../../../data/models/user_models.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/theme/theme_controller.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/auth_controller.dart';
import 'change_password_screen.dart';

/// Profil de l'utilisateur connecté : son identité, ses rôles, ses actions de
/// session. Accessible à TOUS les rôles — c'est son propre compte.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key, required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mon profil')),
      body: ListView(
        padding: const EdgeInsets.all(AmpereGeometry.screenMarginMobile),
        children: [
          _IdentityCard(user: user),
          const SizedBox(height: 14),

          _SectionLabel('Sécurité'),
          _ActionTile(
            icon: LucideIcons.keyRound,
            title: 'Changer mon mot de passe',
            subtitle: 'Vos autres appareils devront se reconnecter',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ChangePasswordScreen(forced: false),
              ),
            ),
          ),
          _ActionTile(
            icon: LucideIcons.smartphone,
            title: 'Déconnecter tous mes appareils',
            subtitle: 'Utile en cas de perte ou de vol',
            tone: StatusTone.warn,
            onTap: () => _confirmRevokeAll(context, ref),
          ),
          const SizedBox(height: 14),

          _SectionLabel('Affichage'),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                children: [
                  Icon(LucideIcons.moon, size: 19, color: colors.ink2),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Thème sombre',
                      style: AmpereType.rowTitle.copyWith(color: colors.ink),
                    ),
                  ),
                  Switch(
                    value: themeMode == ThemeMode.dark,
                    onChanged: (isDark) => ref
                        .read(themeModeProvider.notifier)
                        .set(isDark ? ThemeMode.dark : ThemeMode.light),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 22),

          SizedBox(
            height: AmpereGeometry.touchPrimary,
            child: OutlinedButton.icon(
              onPressed: () => ref.read(authControllerProvider.notifier).logout(),
              icon: const Icon(LucideIcons.logOut, size: 19),
              label: const Text('Se déconnecter'),
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.error,
                side: BorderSide(color: colors.error, width: 1),
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Action destructive (coupe l'accès sur tous les appareils) : elle mérite un
  /// dialogue de confirmation — contrairement aux actions ordinaires (§12.7).
  Future<void> _confirmRevokeAll(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Déconnecter tous les appareils ?'),
        content: const Text(
          'Toutes vos sessions seront fermées, y compris celle-ci. '
          'Vous devrez vous reconnecter.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Tout déconnecter'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      await ref.read(authControllerProvider.notifier).logout(allDevices: true);
    }
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AmpereGeometry.cardPaddingMobile),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const AmpereIconChip(icon: LucideIcons.user, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.fullName,
                        style: AmpereType.sectionTitle.copyWith(color: colors.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        user.email ?? user.phone ?? '—',
                        style: AmpereType.meta.copyWith(color: colors.ink3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const AmpereFieldLabel('Rôles'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final code in user.roles)
                  AmpereBadge(
                    label: AppRoleCode.fromCode(code)?.label ?? code,
                    tone: StatusTone.info,
                    icon: LucideIcons.shield,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${user.permissions.length} permission'
              '${user.permissions.length > 1 ? 's' : ''} effective'
              '${user.permissions.length > 1 ? 's' : ''}',
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: AmpereType.label.copyWith(color: AmpereColors.of(context).ink3),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.tone = StatusTone.info,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final StatusTone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AmpereGeometry.cardRadiusMobile),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AmpereGeometry.cardRadiusMobile),
          child: Container(
            // Cible tactile : jamais sous 56 pour une ligne de liste (§7).
            constraints: const BoxConstraints(minHeight: AmpereGeometry.listRowMin),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              border: Border.all(color: colors.line, width: 1),
              borderRadius: BorderRadius.circular(AmpereGeometry.cardRadiusMobile),
            ),
            child: Row(
              children: [
                AmpereIconChip(icon: icon, tone: tone, size: 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: AmpereType.rowTitle.copyWith(color: colors.ink),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AmpereType.meta.copyWith(color: colors.ink3),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(LucideIcons.chevronRight, size: 18, color: colors.ink3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
