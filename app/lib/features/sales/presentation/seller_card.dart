import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/money.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/data/auth_models.dart';
import '../../users/data/user_models.dart';
import '../../users/presentation/user_photo.dart';
import '../application/sales_controller.dart';
import '../data/sales_models.dart';

/// « Qui vend ? » (demande MEDMEDBEN du 2026-11-09) : la photo du compte
/// connecté, en tête du panier. Un toucher ouvre la fiche : le vendeur vérifie
/// que la session ouverte est bien la SIENNE avant d'encaisser.
class SellerButton extends StatelessWidget {
  const SellerButton({super.key, required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final first = user.fullName.trim().split(RegExp(r'\s+')).first;
    return Tooltip(
      message: 'Ma session : vérifier que c’est bien moi',
      child: Material(
        color: colors.surface2,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openFormPanel<void>(context, SellerPanel(user: user)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(3, 3, 12, 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                UserAvatar(name: user.fullName, size: 30),
                ...[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 110),
                    child: Text(
                      first,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(LucideIcons.info, size: 15, color: colors.ink3),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// La fiche : photo en grand, identité, rôles, ventes du jour, caisse.
class SellerPanel extends ConsumerWidget {
  const SellerPanel({super.key, required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final now = DateTime.now();
    bool today(DateTime d) {
      final l = d.toLocal();
      return l.year == now.year && l.month == now.month && l.day == now.day;
    }

    // Ventes du jour de CE compte (le vendeur ne lit que les siennes ; l'admin
    // lit tout, d'où le filtre par nom).
    final sales = ref.watch(mySalesProvider);
    final mine = [
      for (final s in sales.value ?? const <Sale>[])
        if (today(s.soldAt) &&
            s.cancelledAt == null &&
            (s.sellerName.isEmpty || s.sellerName == user.fullName))
          s,
    ];
    final cash = ref.watch(currentCashSessionProvider).value;

    Widget stat(IconData icon, String label, String value, Color tone) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tone.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 16, color: tone),
                const SizedBox(height: 6),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AmpereType.numeric.copyWith(color: colors.ink),
                ),
                Text(
                  label,
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
              ],
            ),
          ),
        );

    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: colors.ink3),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: AmpereType.body.copyWith(color: colors.ink2),
            ),
          ),
        ],
      ),
    );

    return FormPanelFrame(
      formKey: GlobalKey<FormState>(),
      title: 'Ma session',
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [colors.accent, colors.accent.withValues(alpha: 0.2)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: UserAvatar(name: user.fullName, size: 128),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          user.fullName,
          textAlign: TextAlign.center,
          style: AmpereType.h3.copyWith(color: colors.ink),
        ),
        const SizedBox(height: 4),
        Text(
          formatRoles(user.roles),
          textAlign: TextAlign.center,
          style: AmpereType.meta.copyWith(color: colors.accent),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
          decoration: BoxDecoration(
            color: colors.surface2,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              if (user.email case final email?) line(LucideIcons.mail, email),
              if (user.phone case final phone?) line(LucideIcons.phone, phone),
              line(LucideIcons.calendarDays, formatDate(now)),
              line(LucideIcons.monitorSmartphone, 'Connecté sur cet appareil'),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            stat(
              LucideIcons.receipt,
              'Ventes du jour',
              sales.hasValue ? '${mine.length}' : '—',
              colors.info,
            ),
            const SizedBox(width: 10),
            stat(
              LucideIcons.banknote,
              'Total du jour',
              sales.hasValue
                  ? formatDA(mine.fold<int>(0, (sum, s) => sum + s.totalTtc))
                  : '—',
              colors.ok,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            stat(
              cash == null ? LucideIcons.lock : LucideIcons.wallet,
              cash == null ? 'Caisse fermée' : 'Caisse du magasin',
              cash == null ? '—' : formatDA(cash.currentAmount),
              cash == null ? colors.warn : colors.accent,
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          'Ce n’est pas vous ? Changez de compte avant de vendre : chaque '
          'vente est enregistrée au nom de la session ouverte.',
          textAlign: TextAlign.center,
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () async {
            Navigator.of(context).pop();
            await ref.read(authControllerProvider.notifier).logout();
          },
          icon: const Icon(LucideIcons.logOut, size: 16),
          label: const Text('Changer de compte'),
        ),
      ],
    );
  }
}
