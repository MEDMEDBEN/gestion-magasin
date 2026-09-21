import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../application/planning_controller.dart';
import '../data/planning_api.dart';
import '../data/planning_models.dart';
import 'planning_task_form.dart';

/// Droits planning, MIROIRS des guards serveur (`docs/permissions.md`) :
/// planifier = ADMIN + planning.manage ; voir et exécuter SES tâches = les
/// trois rôles + planning.task.read.
class PlanningRights {
  PlanningRights(this.user)
    : canManage = user.hasRole('ADMIN') && user.can('planning.manage'),
      canRead = user.can('planning.task.read');

  final AuthUser user;
  final bool canManage;
  final bool canRead;

  /// Démarrer/terminer : le membre assigné, ou l'admin.
  bool canWork(PlanningTask task) =>
      canRead && (user.hasRole('ADMIN') || task.assignedToId == user.id);
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: 'Fermer', onPressed: () {}),
      ),
    );
}

/// Le retard prime sur le statut : c'est ce qu'il faut voir en premier.
({String label, StatusTone tone}) _badge(PlanningTask task) {
  if (task.isLate) return (label: 'En retard', tone: StatusTone.error);
  return switch (task.status) {
    PlanningTaskStatus.todo => (label: 'À faire', tone: StatusTone.neutral),
    PlanningTaskStatus.inProgress => (label: 'En cours', tone: StatusTone.info),
    PlanningTaskStatus.done => (label: 'Terminée', tone: StatusTone.ok),
  };
}

/// Planning hebdomadaire (spec §23). L'admin voit tout — filtre par membre et
/// « en retard » — et planifie ; chaque membre ne voit que SES tâches.
class PlanningScreen extends ConsumerStatefulWidget {
  const PlanningScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<PlanningScreen> createState() => _PlanningScreenState();
}

class _PlanningScreenState extends ConsumerState<PlanningScreen> {
  String? _memberId;
  PlanningView _view = PlanningView.open;

  PlanningFilter get _filter => (assignedToId: _memberId, view: _view);

  @override
  Widget build(BuildContext context) {
    final rights = PlanningRights(widget.user);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final tasks = ref.watch(planningTasksProvider(_filter));
    final members = rights.canManage
        ? {
            for (final m
                in ref.watch(assignableMembersProvider).value ?? const [])
              m.id: m.fullName,
          }
        : const <String, String>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              if (rights.canManage)
                SizedBox(
                  width: 240,
                  child: DropdownButtonFormField<String?>(
                    icon: const Icon(LucideIcons.chevronDown, size: 17),
                    initialValue: _memberId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Membre'),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Toute l’équipe'),
                      ),
                      for (final e in members.entries)
                        DropdownMenuItem<String?>(
                          value: e.key,
                          child: Text(e.value),
                        ),
                    ],
                    onChanged: (v) => setState(() => _memberId = v),
                  ),
                ),
              SegmentedButton<PlanningView>(
                segments: [
                  for (final v in PlanningView.values)
                    ButtonSegment(value: v, label: Text(v.label)),
                ],
                selected: {_view},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _view = s.first),
              ),
              if (rights.canManage)
                FilledButton.icon(
                  onPressed: () =>
                      openFormPanel<void>(context, const PlanningTaskForm()),
                  icon: const Icon(LucideIcons.plus, size: 17),
                  label: const Text('Nouvelle tâche'),
                ),
            ],
          ),
        ),
        Expanded(
          child: tasks.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException ? error.userMessage : '$error',
              onRetry: () => ref.invalidate(planningTasksProvider(_filter)),
            ),
            data: (listing) => listing.tasks.isEmpty
                ? ScreenStateView(
                    status: ScreenStatus.empty,
                    title: switch (_view) {
                      PlanningView.open => 'Aucune tâche à faire',
                      PlanningView.late => 'Rien en retard',
                      PlanningView.done => 'Aucune tâche terminée',
                    },
                    message: rights.canManage
                        ? 'Planifiez la semaine : saisies, comptages, révisions.'
                        : 'Aucune tâche ne vous est confiée pour le moment.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      // Page tronquée : on le DIT, on ne perd rien en silence.
                      if (listing.total > listing.tasks.length)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: AmpereInlineAlert(
                            tone: StatusTone.info,
                            icon: LucideIcons.info,
                            message:
                                '${listing.tasks.length} tâches affichées sur '
                                '${listing.total} — filtrez par membre pour '
                                'voir les autres.',
                          ),
                        ),
                      for (final t in listing.tasks)
                        Card(
                          child: ListTile(
                            title: Text(t.title),
                            subtitle: Text(
                              [
                                t.type.label,
                                if (rights.canManage)
                                  members[t.assignedToId] ?? 'Membre',
                                'échéance ${formatIsoDay(t.dueDate)}',
                                ?t.zone,
                              ].join(' · '),
                            ),
                            trailing: AmpereBadge(
                              label: _badge(t).label,
                              tone: _badge(t).tone,
                            ),
                            onTap: () => _openActions(t, rights),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// Actions proposées = celles que le serveur accepterait à cet instant.
  Future<void> _openActions(PlanningTask task, PlanningRights rights) async {
    final open = task.status.isOpen;
    final work = rights.canWork(task);
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(task.title),
        children: [
          if (task.status == PlanningTaskStatus.todo && work)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('start'),
              child: const Text('Commencer'),
            ),
          if (open && work)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('complete'),
              child: const Text('Terminer et donner le résultat'),
            ),
          if (open && rights.canManage)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('edit'),
              child: const Text('Modifier / réassigner'),
            ),
          if (task.status == PlanningTaskStatus.todo && rights.canManage)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('remove'),
              child: const Text('Supprimer la tâche'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('details'),
            child: const Text('Voir le détail'),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case 'edit':
        await openFormPanel<void>(context, PlanningTaskForm(existing: task));
        return;
      case 'details':
        await _showDetails(task);
        return;
      case 'complete':
        final outcome = await showDialog<({String result, String? comment})>(
          context: context,
          builder: (context) => _CompleteDialog(title: task.title),
        );
        if (outcome == null || !mounted) return;
        await _run(
          () => ref
              .read(planningActionsProvider)
              .complete(task.id, outcome.result, outcome.comment),
          '« ${task.title} » terminée.',
        );
        return;
      case 'remove':
        final sure = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Supprimer « ${task.title} » ?'),
            content: const Text(
              'Personne ne l’a commencée : elle disparaît du planning. Le '
              'geste reste tracé dans l’audit.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Garder'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Supprimer'),
              ),
            ],
          ),
        );
        if (sure != true || !mounted) return;
        await _run(
          () => ref.read(planningActionsProvider).remove(task.id),
          '« ${task.title} » supprimée.',
        );
        return;
      default:
        await _run(
          () => ref.read(planningActionsProvider).start(task.id),
          '« ${task.title} » commencée.',
        );
    }
  }

  Future<void> _run(Future<Object?> Function() call, String done) async {
    try {
      await call();
      if (mounted) _snack(context, done);
    } on ApiException catch (error) {
      // Un collègue (ou l'admin) est passé avant : on relit la réalité.
      if (error.statusCode == 409 || error.statusCode == 404) {
        ref.invalidate(planningTasksProvider);
      }
      if (mounted) _snack(context, error.userMessage);
    }
  }

  Future<void> _showDetails(PlanningTask task) async {
    final colors = AmpereColors.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(task.title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${task.type.label} · prévue le ${formatIsoDay(task.scheduledFor)} '
                '· échéance ${formatIsoDay(task.dueDate)}',
              ),
              if (task.description != null) ...[
                const SizedBox(height: 8),
                Text(task.description!),
              ],
              if (task.result != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Résultat : ${task.result}',
                  style: TextStyle(color: colors.ink),
                ),
              ],
              if (task.comment != null)
                Text(
                  'Commentaire : ${task.comment}',
                  style: TextStyle(color: colors.ink3),
                ),
              if (task.completedAt != null)
                Text(
                  'Terminée le ${formatDateTime(task.completedAt!)}',
                  style: TextStyle(color: colors.ink3),
                ),
            ],
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

/// Fin de tâche : résultat OBLIGATOIRE (le serveur le refuse sinon). Dialogue à
/// état pour que les contrôleurs vivent jusqu'à la fin de l'animation.
class _CompleteDialog extends StatefulWidget {
  const _CompleteDialog({required this.title});

  final String title;

  @override
  State<_CompleteDialog> createState() => _CompleteDialogState();
}

class _CompleteDialogState extends State<_CompleteDialog> {
  final _result = TextEditingController();
  final _comment = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _result.dispose();
    _comment.dispose();
    super.dispose();
  }

  void _submit() {
    final result = _result.text.trim();
    if (result.length < 2) {
      setState(() => _error = 'Indiquez le résultat (2 caractères minimum)');
      return;
    }
    final comment = _comment.text.trim();
    Navigator.of(
      context,
    ).pop((result: result, comment: comment.isEmpty ? null : comment));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Terminer « ${widget.title} »'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _result,
            autofocus: true,
            maxLength: 1000,
            decoration: InputDecoration(
              labelText: 'Résultat',
              hintText: '120 m comptés, conforme',
              errorText: _error,
            ),
          ),
          TextField(
            controller: _comment,
            maxLength: 1000,
            decoration: const InputDecoration(
              labelText: 'Commentaire (facultatif)',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Revenir'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Terminer')),
      ],
    );
  }
}
