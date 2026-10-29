import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../ui/widgets/page_kit.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/audit_controller.dart';
import '../data/audit_models.dart';
import '../../../ui/widgets/period_filter.dart';

StatusTone _tone(AuditAction action) => switch (action) {
  AuditAction.create => StatusTone.ok,
  AuditAction.update => StatusTone.info,
  AuditAction.cancel => StatusTone.error,
  AuditAction.validate => StatusTone.ok,
  AuditAction.adjust => StatusTone.warn,
  AuditAction.close => StatusTone.neutral,
  AuditAction.reject => StatusTone.error,
};

/// Libellé des filtres rapides (pluriel) et icône de chaque action.
(String, IconData) _actionLook(AuditAction action) => switch (action) {
  AuditAction.create => ('Créations', LucideIcons.circlePlus),
  AuditAction.update => ('Modifications', LucideIcons.pencil),
  AuditAction.cancel => ('Annulations', LucideIcons.ban),
  AuditAction.validate => ('Validations', LucideIcons.badgeCheck),
  AuditAction.adjust => ('Ajustements', LucideIcons.slidersHorizontal),
  AuditAction.close => ('Clôtures', LucideIcons.archive),
  AuditAction.reject => ('Refus', LucideIcons.circleX),
};

/// « Aujourd'hui », « Hier » ou la date : les lignes sont rangées par jour.
String _dayLabel(DateTime at) {
  final day = DateUtils.dateOnly(at.toLocal());
  final today = DateUtils.dateOnly(DateTime.now());
  if (day == today) return 'Aujourd’hui';
  if (day == today.subtract(const Duration(days: 1))) return 'Hier';
  return formatDate(day);
}

/// Historique global (spec §24) — ADMIN seul, lecture seule. Qui a fait quoi,
/// sur quel objet, et ce qui a changé. Les ventes courantes n'y sont pas : elles
/// vivent dans le module Ventes.
class AuditScreen extends ConsumerWidget {
  const AuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final filter = ref.watch(auditFilterProvider);
    final setFilter = ref.read(auditFilterProvider.notifier).set;
    final journal = ref.watch(auditProvider);
    final colors = AmpereColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 0),
          child: const AmpereInlineAlert(
            tone: StatusTone.info,
            icon: LucideIcons.shieldCheck,
            message:
                'Qui a fait quoi, et quand : prix, stock, validations, '
                'annulations, comptes. Rien ne s’efface. Touchez une ligne pour '
                'voir exactement ce qui a changé.',
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 10, margin, 0),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('Toutes les actions'),
                selected: filter.action == null,
                onSelected: (_) => setFilter((
                  entityType: filter.entityType,
                  action: null,
                  period: filter.period,
                )),
              ),
              for (final a in AuditAction.values)
                ChoiceChip(
                  avatar: Icon(
                    _actionLook(a).$2,
                    size: 15,
                    color: _tone(a).foreground(colors),
                  ),
                  label: Text(_actionLook(a).$1),
                  selected: filter.action == a,
                  selectedColor: _tone(a).background(colors),
                  side: BorderSide(
                    color: filter.action == a
                        ? _tone(a).foreground(colors)
                        : colors.line,
                  ),
                  showCheckmark: false,
                  onSelected: (_) => setFilter((
                    entityType: filter.entityType,
                    action: filter.action == a ? null : a,
                    period: filter.period,
                  )),
                ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 10, margin, 10),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String?>(
                  icon: const Icon(LucideIcons.chevronDown, size: 17),
                  initialValue: filter.entityType,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Objet'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Tous les objets'),
                    ),
                    for (final e in auditEntityLabels.entries)
                      DropdownMenuItem<String?>(
                        value: e.key,
                        child: Text(e.value),
                      ),
                  ],
                  onChanged: (v) => setFilter((
                    entityType: v,
                    action: filter.action,
                    period: filter.period,
                  )),
                ),
              ),
              PeriodFilter(
                value: filter.period,
                onChanged: (p) => setFilter((
                  entityType: filter.entityType,
                  action: filter.action,
                  period: p,
                )),
              ),
            ],
          ),
        ),
        Expanded(
          child: journal.when(
            loading: () => const AmpereSkeletonList(rows: 6),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException ? error.userMessage : '$error',
              onRetry: () => ref.invalidate(auditProvider),
            ),
            data: (state) => state.items.isEmpty
                ? const ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Aucune action sur la période',
                    message:
                        'Prix, ajustements, validations, annulations et droits '
                        'des membres apparaissent ici. Élargissez la période '
                        '(« Tout ») pour remonter plus loin.',
                  )
                : ListView(
                    padding: withNavBar(
                      context,
                      EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    ),
                    children: [
                      for (var k = 0; k < state.items.length; k++) ...[
                        if (k == 0 ||
                            _dayLabel(state.items[k].createdAt) !=
                                _dayLabel(state.items[k - 1].createdAt))
                          Padding(
                            padding: const EdgeInsets.fromLTRB(2, 10, 0, 6),
                            child: Text(
                              _dayLabel(state.items[k].createdAt).toUpperCase(),
                              style: AmpereType.label.copyWith(
                                color: colors.ink3,
                              ),
                            ),
                          ),
                        _EntryTile(entry: state.items[k]),
                      ],
                      if (state.hasMore)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Center(
                            child: TextButton.icon(
                              onPressed: state.isLoadingMore
                                  ? null
                                  : () => _loadMore(context, ref),
                              icon: const Icon(
                                LucideIcons.chevronDown,
                                size: 16,
                              ),
                              label: Text(
                                'Afficher plus (${state.items.length} sur '
                                '${state.total})',
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// La page suivante n'arrive pas : la liste chargée reste, et l'échec se DIT.
Future<void> _loadMore(BuildContext context, WidgetRef ref) async {
  try {
    await ref.read(auditProvider.notifier).loadMore();
  } on ApiException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.userMessage)));
    }
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final changes = auditChanges(entry.oldValue, entry.newValue);
    final colors = AmpereColors.of(context);
    final tone = _tone(entry.action);
    final first = changes.isEmpty ? null : changes.first;
    return Card(
      child: ListTile(
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: tone.background(colors),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            _actionLook(entry.action).$2,
            size: 18,
            color: tone.foreground(colors),
          ),
        ),
        title: Text(
          '${auditEntityLabel(entry.entityType)} · ${entry.action.label}',
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${entry.userName ?? 'Système'} · ${formatDateTime(entry.createdAt)}'
              '${changes.isEmpty ? '' : ' · ${changes.length} champ(s)'}',
            ),
            // Le changement principal sans ouvrir la fiche.
            if (first != null)
              Text(
                first.before.isEmpty || first.after.isEmpty
                    ? '${first.field} : ${first.after.isEmpty ? first.before : first.after}'
                    : '${first.field} : ${first.before} → ${first.after}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AmpereType.meta.copyWith(color: colors.ink2),
              ),
          ],
        ),
        trailing: AmpereBadge(
          label: entry.action.label,
          tone: _tone(entry.action),
        ),
        onTap: () => _showDetails(context, changes),
      ),
    );
  }

  Future<void> _showDetails(
    BuildContext context,
    List<AuditChange> changes,
  ) async {
    final colors = AmpereColors.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '${auditEntityLabel(entry.entityType)} · ${entry.action.label}',
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.userName ?? 'Système'} · '
                  '${formatDateTime(entry.createdAt)}'
                  '${entry.ipAddress == null ? '' : ' · ${entry.ipAddress}'}',
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
                const SizedBox(height: 12),
                if (changes.isEmpty)
                  const Text('Aucun champ modifié.')
                else
                  for (final c in changes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.field,
                            style: AmpereType.bodyStrong.copyWith(
                              color: colors.ink,
                            ),
                          ),
                          Text(
                            // Création : pas d'avant ; annulation : pas d'après.
                            c.before.isEmpty
                                ? c.after
                                : c.after.isEmpty
                                ? c.before
                                : '${c.before}  →  ${c.after}',
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }
}
