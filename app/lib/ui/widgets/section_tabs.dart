import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'motion.dart';
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

/// Une section regroupée (2026-10-28) : une barre d'onglets soulignés, fine,
/// distincte des onglets internes des écrans, puis la rubrique choisie.
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
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0.03, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(
        key: ValueKey('$group/${current.label}'),
        child: current.builder(context, user),
      ),
    );
    if (MediaQuery.sizeOf(context).width < 600) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.line)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            // Le soulignement GLISSE vers la rubrique choisie.
            child: SlidingSelection(
              selected: index,
              indicator: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: colors.accent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
              children: [
                for (final (i, s) in sections.indexed)
                  _Tab(
                    icon: s.icon,
                    label: sectionTabLabels[s.label] ?? s.label,
                    selected: i == index,
                    onTap: () =>
                        ref.read(sectionIndexProvider.notifier).set(group, i),
                  ),
              ],
            ),
          ),
        ),
        Expanded(child: content),
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final ink = selected ? colors.ink : colors.ink3;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          decoration: BoxDecoration(
            border: Border(
              // Le soulignement est dessiné par la barre (il glisse).
              bottom: const BorderSide(color: Colors.transparent, width: 2),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: ink),
              const SizedBox(width: 7),
              Text(
                label,
                style: AmpereType.bodyStrong.copyWith(
                  color: ink,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
