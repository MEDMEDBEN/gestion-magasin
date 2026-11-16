import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/money.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/contact_profile.dart';
import '../../payments/data/payment_models.dart';
import '../data/suppliers_api.dart';
import '../data/suppliers_models.dart';

/// Une action de la fiche (rendue à l'écran, qui la fait).
typedef SupplierAction = ({IconData icon, String label, String value});

/// Derniers paiements d'un fournisseur (lus en ligne ; hors ligne : rien).
final _recentPaymentsProvider = FutureProvider.autoDispose
    .family<List<PaymentHistoryItem>, String>((ref, supplierId) async {
      try {
        final page = await ref.watch(suppliersApiProvider).payments(supplierId);
        return page.data.take(6).toList();
      } on Object {
        return const [];
      }
    });

/// FICHE FOURNISSEUR (demande MEDMEDBEN du 2026-11-15 : « moderne, avec une
/// vie ») : qui il est, ce qu'on lui doit — en grand, avec la part déjà
/// payée —, un gros bouton « Versement », les gestes du compte en tuiles, et
/// les derniers paiements. Rend l'action choisie, ou `null`.
Future<String?> showSupplierAccount(
  BuildContext context, {
  required Supplier supplier,
  required bool canPay,
  required List<SupplierAction> actions,
  required bool canDelete,
}) => showAmpereSidePanel<String>(
  context: context,
  width: 480,
  builder: (_) => _SupplierAccount(
    supplier: supplier,
    canPay: canPay,
    actions: actions,
    canDelete: canDelete,
  ),
);

class _SupplierAccount extends ConsumerWidget {
  const _SupplierAccount({
    required this.supplier,
    required this.canPay,
    required this.actions,
    required this.canDelete,
  });

  final Supplier supplier;
  final bool canPay;
  final List<SupplierAction> actions;
  final bool canDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final s = supplier;
    final owed = s.openingBalance + s.receivedAmount;
    final paidShare = owed <= 0 ? 1.0 : (s.paidAmount / owed).clamp(0.0, 1.0);
    final due = s.balanceDue;
    final tone = due > 0 ? colors.warn : colors.ok;
    void close(String? value) => Navigator.of(context).pop(value);

    final contacts = [
      if (s.phone case final v? when v.isNotEmpty) (LucideIcons.phone, v),
      if (s.email case final v? when v.isNotEmpty) (LucideIcons.mail, v),
      if (s.contactName case final v? when v.isNotEmpty)
        (LucideIcons.userRound, v),
      if (s.address case final v? when v.isNotEmpty) (LucideIcons.mapPin, v),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── En-tête : avatar, nom, fermer ──────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 8, 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [colors.accentBg, colors.surface],
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: colors.accent,
                child: Text(
                  initialsOf(s.name),
                  style: AmpereType.h4.copyWith(color: colors.onAccent),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.h3.copyWith(color: colors.ink),
                    ),
                    Text(
                      'Fournisseur',
                      style: AmpereType.meta.copyWith(color: colors.ink3),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Fermer',
                onPressed: () => close(null),
                icon: const Icon(LucideIcons.x, size: 19),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            children: [
              // ── Coordonnées : un geste pour copier ────────────────────
              if (contacts.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (icon, text) in contacts)
                      ActionChip(
                        avatar: Icon(icon, size: 15),
                        label: Text(text, overflow: TextOverflow.ellipsis),
                        tooltip: 'Copier',
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Copié : $text')),
                            );
                          }
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],

              // ── La dette, en grand ────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: due > 0 ? colors.warnBg : colors.okBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      due > 0
                          ? 'VOUS LUI DEVEZ'
                          : due < 0
                          ? 'IL VOUS DOIT (trop-payé)'
                          : 'COMPTE SOLDÉ',
                      style: AmpereType.label.copyWith(color: tone),
                    ),
                    const SizedBox(height: 4),
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: due.abs().toDouble()),
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.easeOutCubic,
                      builder: (context, v, _) => Text(
                        formatDA(v.round()),
                        style: AmpereType.h1.copyWith(
                          color: colors.ink,
                          fontFeatures: AmpereType.tabular,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: paidShare),
                        duration: const Duration(milliseconds: 800),
                        curve: Curves.easeOutCubic,
                        builder: (context, v, _) => LinearProgressIndicator(
                          value: v,
                          minHeight: 10,
                          color: colors.ok,
                          backgroundColor: colors.surface,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _Mini(
                            label: 'Marchandise reçue',
                            value: formatDA(s.receivedAmount),
                          ),
                        ),
                        Expanded(
                          child: _Mini(
                            label: 'Déjà payé',
                            value: formatDA(s.paidAmount),
                          ),
                        ),
                        if (s.openingBalance != 0)
                          Expanded(
                            child: _Mini(
                              label: 'Dette reprise',
                              value: formatDA(s.openingBalance),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ── Le geste principal : verser ───────────────────────────
              if (canPay && due > 0) ...[
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: colors.ok,
                    foregroundColor: colors.bg,
                    textStyle: AmpereType.h4,
                  ),
                  onPressed: () => close('pay'),
                  icon: const Icon(LucideIcons.handCoins, size: 20),
                  label: const Text('Versement'),
                ),
                const SizedBox(height: 6),
                Text(
                  'Le versement réduit la dette ; il peut sortir de la caisse.',
                  textAlign: TextAlign.center,
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
                const SizedBox(height: 16),
              ],

              // ── Les gestes du compte, en tuiles ───────────────────────
              LayoutBuilder(
                builder: (context, box) {
                  final width = (box.maxWidth - 8) / 2;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final a in actions)
                        if (a.value != 'pay')
                          SizedBox(
                            width: width,
                            child: Material(
                              color: colors.surface2,
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => close(a.value),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Row(
                                    children: [
                                      Icon(
                                        a.icon,
                                        size: 18,
                                        color: colors.accent,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          a.label,
                                          maxLines: 2,
                                          style: AmpereType.bodyStrong.copyWith(
                                            color: colors.ink,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),

              // ── La vie du compte : derniers paiements ─────────────────
              Text(
                'DERNIERS PAIEMENTS',
                style: AmpereType.label.copyWith(color: colors.ink3),
              ),
              const SizedBox(height: 6),
              switch (ref.watch(_recentPaymentsProvider(s.id))) {
                AsyncValue(:final value?) when value.isEmpty => Text(
                  'Aucun paiement pour l’instant.',
                  style: AmpereType.body.copyWith(color: colors.ink3),
                ),
                AsyncValue(:final value?) => Column(
                  children: [
                    for (final p in value)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: p.amount < 0
                                    ? colors.errorBg
                                    : colors.okBg,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                p.fromCash
                                    ? LucideIcons.wallet
                                    : LucideIcons.landmark,
                                size: 15,
                                color: p.amount < 0 ? colors.error : colors.ok,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    p.note?.isNotEmpty == true
                                        ? p.note!
                                        : p.fromCash
                                        ? 'Versement (caisse)'
                                        : 'Versement',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AmpereType.body.copyWith(
                                      color: colors.ink,
                                    ),
                                  ),
                                  Text(
                                    formatDate(p.paidAt.toLocal()),
                                    style: AmpereType.meta.copyWith(
                                      color: colors.ink3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              formatDA(p.amount),
                              style: AmpereType.bodyStrong.copyWith(
                                color: p.amount < 0 ? colors.error : colors.ok,
                                fontFeatures: AmpereType.tabular,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                _ => const LinearProgressIndicator(minHeight: 2),
              },
              if (canDelete) ...[
                const SizedBox(height: 20),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: colors.error),
                  onPressed: () => close(contactDeleteAction),
                  icon: const Icon(LucideIcons.trash2, size: 16),
                  label: const Text('Supprimer ce fournisseur'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AmpereType.meta.copyWith(color: colors.ink3)),
        Text(
          value,
          style: AmpereType.bodyStrong.copyWith(
            color: colors.ink,
            fontFeatures: AmpereType.tabular,
          ),
        ),
      ],
    );
  }
}
