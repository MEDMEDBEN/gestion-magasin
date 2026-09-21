import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../users/data/user_models.dart';
import '../../users/data/users_api.dart';
import '../data/planning_api.dart';
import '../data/planning_models.dart';

/// Filtre de l'écran : le membre dont on regarde le travail (admin seulement)
/// et la vue (à faire / en retard / terminées).
typedef PlanningFilter = ({String? assignedToId, PlanningView view});

/// Une page de tâches et le nombre total côté serveur : si la page ne montre
/// pas tout, l'écran le DIT au lieu de perdre des tâches en silence.
typedef PlanningListing = ({List<PlanningTask> tasks, int total});

/// Tâches lues EN LIGNE, liées au compte connecté (poste partagé). Le serveur
/// ne rend à un non-admin que SES tâches, quel que soit le filtre.
final planningTasksProvider = FutureProvider.autoDispose
    .family<PlanningListing, PlanningFilter>((ref, filter) async {
      ref.watch(currentUserIdProvider);
      final page = await ref
          .watch(planningApiProvider)
          .list(assignedToId: filter.assignedToId, view: filter.view);
      return (tasks: page.data, total: page.meta.total);
    });

/// Membres actifs à qui l'admin peut confier une tâche (et dont il lit le nom).
/// Réservé à l'admin : `/users` est fermé aux autres rôles.
final assignableMembersProvider = FutureProvider.autoDispose<List<ManagedUser>>(
  (ref) async {
    ref.watch(currentUserIdProvider);
    final page = await ref.watch(usersApiProvider).list(limit: 200);
    return [
      for (final u in page.data)
        if (u.isActive) u,
    ];
  },
);

/// Tâche saisie dans le formulaire (avant envoi au serveur).
typedef PlanningTaskDraft = ({
  String title,
  PlanningTaskType type,
  String assignedToId,
  String scheduledFor,
  String dueDate,
  String? zone,
  String? description,
});

Map<String, Object?> _fields(PlanningTaskDraft draft) => {
  'title': draft.title,
  'type': draft.type.wire,
  'assignedToId': draft.assignedToId,
  'scheduledFor': draft.scheduledFor,
  'dueDate': draft.dueDate,
  'zone': draft.zone,
  'description': draft.description,
};

/// Ce qui a RÉELLEMENT changé par rapport à la tâche enregistrée. Renvoyer une
/// échéance passée inchangée la ferait refuser : une tâche en retard ne se
/// réassignerait plus (revue du 2026-09-21).
Map<String, Object?> planningChanges(
  PlanningTask existing,
  PlanningTaskDraft draft,
) {
  final before = _fields((
    title: existing.title,
    type: existing.type,
    assignedToId: existing.assignedToId,
    scheduledFor: existing.scheduledFor,
    dueDate: existing.dueDate,
    zone: existing.zone,
    description: existing.description,
  ));
  return {
    for (final entry in _fields(draft).entries)
      if (before[entry.key] != entry.value) entry.key: entry.value,
  };
}

/// Écritures du planning — toujours validées par le serveur.
class PlanningActions {
  PlanningActions(this._ref);

  final Ref _ref;

  PlanningApi get _api => _ref.read(planningApiProvider);

  /// `id` : UUID stable du formulaire, un renvoi ne crée pas de doublon.
  Future<PlanningTask> create(String id, PlanningTaskDraft draft) =>
      _refresh(_api.create({'id': id, ..._fields(draft)}));

  Future<PlanningTask> update(PlanningTask existing, PlanningTaskDraft draft) =>
      _refresh(_api.update(existing.id, planningChanges(existing, draft)));

  Future<PlanningTask> start(String id) => _refresh(_api.start(id));

  Future<PlanningTask> complete(String id, String result, String? comment) =>
      _refresh(_api.complete(id, result, comment));

  Future<void> remove(String id) async {
    await _api.remove(id);
    _ref.invalidate(planningTasksProvider);
  }

  Future<PlanningTask> _refresh(Future<PlanningTask> call) async {
    final task = await call;
    _ref.invalidate(planningTasksProvider);
    return task;
  }
}

final planningActionsProvider = Provider(PlanningActions.new);
