import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/theme/theme_controller.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../users/data/user_models.dart';
import '../application/auth_controller.dart';
import '../data/auth_models.dart';
import 'change_password_screen.dart';

/// Profil de l'utilisateur connecté : son identité, ses rôles, ses actions de
/// session. Accessible à TOUS les rôles — c'est son propre compte.
///
/// Hébergé dans une coquille : pas d'`AppBar` propre (revue C10).
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _busy = false;
  String? _error;

  /// Action destructive (coupe l'accès sur tous les appareils) : elle mérite un
  /// dialogue de confirmation — contrairement aux actions ordinaires (§12.7).
  /// Un ÉCHEC est affiché et la session conservée : l'utilisateur qui croit son
  /// téléphone volé déconnecté ne doit pas se tromper (audit I3).
  Future<void> _logoutAllDevices() async {
    final confirmed = await showAmpereConfirmDialog(
      context,
      title: 'Déconnecter tous les appareils ?',
      // Réserve honnête (contre-revue S16) : un appareil déjà connecté garde un
      // accès limité jusqu'à l'expiration de son access token (15 min) ; seules
      // les actions sensibles lui sont refusées immédiatement.
      body:
          'Toutes vos sessions seront fermées, y compris celle-ci. '
          'Vous devrez vous reconnecter. Un appareil déjà ouvert peut garder '
          'un accès limité jusqu’à 15 minutes.',
      confirmLabel: 'Tout déconnecter',
    );
    if (!confirmed) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).logoutAllDevices();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error =
            'Révocation NON effectuée : ${error.userMessage}. '
            'Réessayez, ou demandez à l’administrateur de révoquer vos sessions.';
      });
    }
  }

  /// Des opérations saisies sur cet appareil ne sont pas encore synchronisées :
  /// elles restent ici et ne partiront qu'à la prochaine connexion de CE
  /// compte (audit I2). On le dit avant de déconnecter.
  Future<void> _logout(int pending) async {
    if (pending > 0) {
      final confirmed = await showAmpereConfirmDialog(
        context,
        title: 'Opérations non synchronisées',
        body:
            '$pending opération${pending > 1 ? 's' : ''} saisie'
            '${pending > 1 ? 's' : ''} sur cet appareil '
            '${pending > 1 ? 'attendent' : 'attend'} encore le serveur. '
            'Elles resteront ici et ne partiront qu’à votre prochaine '
            'connexion sur cet appareil.',
        confirmLabel: 'Se déconnecter quand même',
      );
      if (!confirmed) return;
    }
    await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final themeMode = ref.watch(themeModeProvider);
    // Écoutés (et non lus à la volée) : un provider non écouté est mis en
    // pause par Riverpod et sa valeur ne serait pas à jour au moment du clic.
    final pending = ref.watch(pendingMutationsCountProvider).value ?? 0;
    final foreignPending =
        ref.watch(foreignPendingMutationsCountProvider).value ?? 0;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(AmpereGeometry.screenMarginMobile),
          children: [
            _IdentityCard(user: widget.user),
            const SizedBox(height: 14),

            if (foreignPending > 0) ...[
              AmpereInlineAlert(
                tone: StatusTone.warn,
                icon: LucideIcons.refreshCw,
                message:
                    '$foreignPending opération'
                    '${foreignPending > 1 ? 's' : ''} saisie'
                    '${foreignPending > 1 ? 's' : ''} par un autre compte '
                    '${foreignPending > 1 ? 'attendent' : 'attend'} sur cet '
                    'appareil. Elles partiront à la prochaine connexion de '
                    'leur auteur, jamais avec votre session.',
              ),
              const SizedBox(height: 14),
            ],

            const _SectionLabel('Sécurité'),
            _ActionTile(
              icon: LucideIcons.keyRound,
              title: 'Changer mon mot de passe',
              subtitle: 'Vos autres appareils devront se reconnecter',
              onTap: _busy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const ChangePasswordScreen(forced: false),
                      ),
                    ),
            ),
            _ActionTile(
              icon: LucideIcons.smartphone,
              title: 'Déconnecter tous mes appareils',
              subtitle: 'Utile en cas de perte ou de vol',
              tone: StatusTone.warn,
              onTap: _busy ? null : _logoutAllDevices,
            ),
            if (_error != null) ...[
              AmpereInlineAlert(message: _error!),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 6),

            const _SectionLabel('Affichage'),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
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
              child: AmpereDangerButton(
                onPressed: _busy ? null : () => _logout(pending),
                icon: LucideIcons.logOut,
                label: 'Se déconnecter',
              ),
            ),
          ],
        ),
      ),
    );
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
                        style: AmpereType.sectionTitle.copyWith(
                          color: colors.ink,
                        ),
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
              style: AmpereType.meta.copyWith(
                color: colors.ink3,
                fontFeatures: AmpereType.tabular,
              ),
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
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AmpereTappable(
        onTap: onTap,
        borderRadius: AmpereGeometry.cardRadiusMobile,
        color: colors.surface,
        child: Container(
          // Cible tactile : jamais sous 56 pour une ligne de liste (§7).
          constraints: const BoxConstraints(
            minHeight: AmpereGeometry.listRowMin,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            border: Border.all(
              color: colors.line,
              width: AmpereGeometry.borderWidth,
            ),
            borderRadius: BorderRadius.circular(
              AmpereGeometry.cardRadiusMobile,
            ),
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
    );
  }
}
