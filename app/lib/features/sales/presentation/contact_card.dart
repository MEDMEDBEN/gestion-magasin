import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/contact_profile.dart';

/// Un geste sur la carte : icône, libellé, action.
typedef ContactAction = (IconData icon, String label, VoidCallback onPressed);

/// Un montant de la carte : libellé, valeur affichée, couleur.
typedef ContactAmount = (String label, String value, Color color);

/// Carte de contact (client, confrère) : avatar à initiales teinté par l'état,
/// nom, téléphone, étiquettes, statut en couleur, montants, jauge de crédit,
/// gestes rapides. Toucher la carte ouvre la fiche.
class ContactCard extends StatelessWidget {
  const ContactCard({
    super.key,
    required this.name,
    this.phone,
    this.tags = const [],
    required this.status,
    required this.tone,
    this.amounts = const [],
    this.gauge,
    this.actions = const [],
    this.onTap,
  });

  final String name;
  final String? phone;
  final List<String> tags;

  /// État en un mot (« À jour », « Dette … »), dans la couleur `tone`.
  final String status;
  final Color tone;
  final List<ContactAmount> amounts;

  /// Part du plafond de crédit utilisée (0..1) et son libellé.
  final ({double ratio, String label})? gauge;
  final List<ContactAction> actions;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Avatar(initials: initialsOf(name), tone: tone),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AmpereType.rowTitle.copyWith(
                            color: colors.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(
                              LucideIcons.phone,
                              size: 13,
                              color: colors.ink3,
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                phone ?? 'Sans téléphone',
                                overflow: TextOverflow.ellipsis,
                                style: AmpereType.meta.copyWith(
                                  color: colors.ink2,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (tags.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              for (final tag in tags)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colors.accentBg,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    tag,
                                    style: AmpereType.label.copyWith(
                                      color: colors.accentHi,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: tone.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      status,
                      style: AmpereType.label.copyWith(color: tone),
                    ),
                  ),
                ],
              ),
              if (amounts.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final (label, value, color) in amounts)
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: AmpereType.meta.copyWith(
                                color: colors.ink3,
                              ),
                            ),
                            Text(
                              value,
                              style: AmpereType.bodyStrong.copyWith(
                                color: color,
                                fontFeatures: AmpereType.tabular,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
              if (gauge case final g?) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: g.ratio.clamp(0, 1),
                    minHeight: 6,
                    color: g.ratio >= 0.9
                        ? colors.error
                        : g.ratio >= 0.6
                        ? colors.warn
                        : colors.ok,
                    backgroundColor: colors.surface3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  g.label,
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 6),
                Divider(height: 1, color: colors.lineSoft),
                Wrap(
                  children: [
                    for (final (icon, label, onPressed) in actions)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: onPressed,
                        icon: Icon(icon, size: 16),
                        label: Text(label),
                      ),
                  ],
                ),
              ] else
                const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.initials, required this.tone});

  final String initials;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tone.withValues(alpha: 0.85), colors.accent],
        ),
      ),
      child: Text(
        initials,
        style: AmpereType.bodyStrong.copyWith(color: colors.onAccent),
      ),
    );
  }
}

/// Grille de cartes : autant de colonnes que la largeur en permet (≈ 360 px).
class ContactGrid extends StatelessWidget {
  const ContactGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const gap = 12.0;
      final columns = (box.maxWidth / 360).floor().clamp(1, 4);
      final width = (box.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

/// Bandeau de chiffres en tête de liste (« 3 clients · 32 340 DA dus »).
class SummaryStrip extends StatelessWidget {
  const SummaryStrip({super.key, required this.items});

  final List<ContactAmount> items;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final (label, value, color) in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.35)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  color.withValues(alpha: 0.12),
                  color.withValues(alpha: 0.02),
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
                Text(
                  value,
                  style: AmpereType.sectionTitle.copyWith(
                    color: color,
                    fontFeatures: AmpereType.tabular,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
