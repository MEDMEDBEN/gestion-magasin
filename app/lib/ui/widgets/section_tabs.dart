import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/data/auth_models.dart';
import '../navigation.dart';
import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';

/// Onglet ouvert de chaque section (clé : libellé de la section). Les
/// coquilles l'écrivent quand un raccourci vise une rubrique regroupée.
class SectionIndex extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  void set(String group, int index) => state = {...state, group: index};
}

final sectionIndexProvider = NotifierProvider<SectionIndex, Map<String, int>>(
  SectionIndex.new,
);

/// Une section regroupée (2026-10-28) : ses pages en boutons, toujours
/// visibles (2026-11-09), puis la page choisie.
class SectionTabs extends ConsumerWidget {
  const SectionTabs({
    super.key,
    required this.group,
    required this.sections,
    required this.user,
  });

  final String group;
  final List<AppDestination> sections;
  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final index = (ref.watch(sectionIndexProvider)[group] ?? 0).clamp(
      0,
      sections.length - 1,
    );
    final current = sections[index];
    // Téléphone : la rubrique se choisit depuis le titre de la page.
    // Changer de rubrique : la nouvelle arrive en fondu, légèrement glissée.
    final content = AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: KeyedSubtree(
        key: ValueKey('$group/${current.label}'),
        child: current.builder(context, user),
      ),
    );
    // Pages de la section TOUJOURS visibles, en vrais boutons (demande
    // MEDMEDBEN du 2026-11-09 : soulignées ou repliées dans le titre, on ne
    // voyait pas qu'il y avait une 2e page — Devis à côté de Vente).
    final phone = MediaQuery.sizeOf(context).width < 600;
    final tabs = [
      for (final (i, s) in sections.indexed)
        _Tab(
          icon: s.icon,
          label: sectionTabLabels[s.label] ?? s.label,
          selected: i == index,
          phone: phone,
          onTap: () => ref.read(sectionIndexProvider.notifier).set(group, i),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(phone ? 12 : 8, 6, phone ? 12 : 8, 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.line)),
          ),
          child: phone
              ? Row(
                  children: [
                    for (final (i, tab) in tabs.indexed) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(child: tab),
                    ],
                  ],
                )
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (i, tab) in tabs.indexed) ...[
                        if (i > 0) const SizedBox(width: 8),
                        tab,
                      ],
                    ],
                  ),
                ),
        ),
        Expanded(child: content),
      ],
    );
  }
}

/// Une page de la section : bouton à contour ; la page ouverte en teinte
/// d'accent (distincte des onglets PLEINS internes aux écrans).
class _Tab extends StatelessWidget {
  const _Tab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.phone,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool phone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final ink = selected ? colors.accent : colors.ink2;
    final radius = BorderRadius.circular(10);
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: radius,
          color: selected ? colors.accentBg : colors.surface,
          border: Border.all(
            color: selected ? colors.accent : colors.line,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: phone ? 8 : 18,
                vertical: phone ? 8 : 7,
              ),
              child: Row(
                mainAxisSize: phone ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 17, color: ink),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.bodyStrong.copyWith(
                        color: selected ? colors.ink : colors.ink2,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
