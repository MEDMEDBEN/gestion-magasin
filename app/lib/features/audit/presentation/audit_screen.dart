import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/audit_controller.dart';
import '../data/audit_models.dart';

StatusTone _tone(AuditAction action) => switch (action) {
  AuditAction.create => StatusTone.ok,
  AuditAction.update => StatusTone.info,
  AuditAction.cancel => StatusTone.error,
  AuditAction.validate => StatusTone.ok,
  AuditAction.adjust => StatusTone.warn,
  AuditAction.close => StatusTone.neutral,
  AuditAction.reject => StatusTone.error,
};

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
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
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<AuditAction?>(
                  icon: const Icon(LucideIcons.chevronDown, size: 17),
                  initialValue: filter.action,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Action'),
                  items: [
                    const DropdownMenuItem<AuditAction?>(
                      value: null,
                      child: Text('Toutes'),
                    ),
                    for (final a in AuditAction.values)
                      DropdownMenuItem<AuditAction?>(
                        value: a,
                        child: Text(a.label),
                      ),
                  ],
                  onChanged: (v) => setFilter((
                    entityType: filter.entityType,
                    action: v,
                    period: filter.period,
                  )),
                ),
              ),
              SegmentedButton<AuditPeriod>(
                segments: [
                  for (final p in AuditPeriod.values)
                    ButtonSegment(value: p, label: Text(p.label)),
                ],
                selected: {filter.period},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setFilter((
                  entityType: filter.entityType,
                  action: filter.action,
                  period: s.first,
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
                        'des membres apparaissent ici.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final e in state.items) _EntryTile(entry: e),
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
    return Card(
      child: ListTile(
        title: Text(
          '${auditEntityLabel(entry.entityType)} · ${entry.action.label}',
        ),
        subtitle: Text(
          '${entry.userName ?? 'Système'} · ${formatDateTime(entry.createdAt)}'
          '${changes.isEmpty ? '' : ' · ${changes.length} champ(s)'}',
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
