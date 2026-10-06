import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import 'ampere_controls.dart';
import 'screen_state.dart';

/// Une action du panneau (« Encaisser un règlement », « Modifier la fiche »…).
typedef ContactAction = ({IconData icon, String label, String value});

/// Un chiffre du compte (« Reste dû », « Total acheté »…).
typedef ContactFigure = ({String label, String value, StatusTone tone});

/// Valeur rendue quand l'utilisateur choisit « Supprimer ».
const contactDeleteAction = 'delete';

/// Fiche CONTACT d'un client ou d'un fournisseur (demande MEDMEDBEN du
/// 2026-10-06) : identité, coordonnées (copiables d'un geste), compte, puis
/// les actions et « Supprimer ». Rend l'action choisie, ou `null`.
Future<String?> showContactProfile(
  BuildContext context, {
  required String name,
  required String kind,
  String? phone,
  String? email,
  String? address,
  String? contactName,
  String? notes,
  List<ContactFigure> figures = const [],
  List<ContactAction> actions = const [],
  bool canDelete = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ContactProfile(
      name: name,
      kind: kind,
      details: [
        if (contactName != null && contactName.isNotEmpty)
          (LucideIcons.userRound, 'Contact', contactName),
        if (phone != null && phone.isNotEmpty)
          (LucideIcons.phone, 'Téléphone', phone),
        if (email != null && email.isNotEmpty)
          (LucideIcons.mail, 'E-mail', email),
        if (address != null && address.isNotEmpty)
          (LucideIcons.mapPin, 'Adresse', address),
        if (notes != null && notes.isNotEmpty)
          (LucideIcons.stickyNote, 'Notes', notes),
      ],
      figures: figures,
      actions: actions,
      canDelete: canDelete,
    ),
  );
}

/// Initiales d'un nom (« Sonelec Distribution » → « SD »).
String initialsOf(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final letters = [for (final w in words.take(2)) w[0].toUpperCase()];
  return letters.isEmpty ? '?' : letters.join();
}

class _ContactProfile extends StatelessWidget {
  const _ContactProfile({
    required this.name,
    required this.kind,
    required this.details,
    required this.figures,
    required this.actions,
    required this.canDelete,
  });

  final String name;
  final String kind;
  final List<(IconData, String, String)> details;
  final List<ContactFigure> figures;
  final List<ContactAction> actions;
  final bool canDelete;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Identité
              Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: colors.accentBg,
                    child: Text(
                      initialsOf(name),
                      style: AmpereType.h4.copyWith(color: colors.accentHi),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: AmpereType.h4.copyWith(color: colors.ink),
                        ),
                        const SizedBox(height: 4),
                        AmpereBadge(label: kind, tone: StatusTone.info),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Fermer',
                    icon: const Icon(LucideIcons.x, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              // ── Coordonnées
              const SizedBox(height: 14),
              if (details.isEmpty)
                Text(
                  'Aucune coordonnée enregistrée.',
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                )
              else
                for (final (icon, label, value) in details)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(icon, size: 18, color: colors.ink2),
                    title: Text(value),
                    subtitle: Text(label),
                    trailing: IconButton(
                      tooltip: 'Copier',
                      icon: const Icon(LucideIcons.copy, size: 16),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: value));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('$label copié')),
                          );
                        }
                      },
                    ),
                  ),
              // ── Compte
              if (figures.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final f in figures)
                      Container(
                        constraints: const BoxConstraints(minWidth: 140),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colors.surface2,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              f.label,
                              style: AmpereType.meta.copyWith(
                                color: colors.ink3,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              f.value,
                              style: AmpereType.bodyStrong.copyWith(
                                color: switch (f.tone) {
                                  StatusTone.error => colors.error,
                                  StatusTone.warn => colors.warn,
                                  StatusTone.ok => colors.ok,
                                  _ => colors.ink,
                                },
                                fontFeatures: AmpereType.tabular,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
              // ── Actions
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                for (final a in actions)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(a.icon, size: 18),
                    title: Text(a.label),
                    onTap: () => Navigator.of(context).pop(a.value),
                  ),
              ],
              if (canDelete) ...[
                const Divider(height: 1),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AmpereDangerButton(
                    icon: LucideIcons.trash2,
                    label: 'Supprimer',
                    onPressed: () =>
                        Navigator.of(context).pop(contactDeleteAction),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
