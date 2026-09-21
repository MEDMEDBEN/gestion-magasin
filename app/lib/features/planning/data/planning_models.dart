import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../data/models/page_meta.dart';

part 'planning_models.freezed.dart';
part 'planning_models.g.dart';

/// Machine à états figée (`docs/plan.md`) : A_FAIRE → EN_COURS → TERMINEE.
/// EN_RETARD n'est PAS un statut : le serveur le calcule (`isLate`).
enum PlanningTaskStatus {
  @JsonValue('A_FAIRE')
  todo('À faire'),
  @JsonValue('EN_COURS')
  inProgress('En cours'),
  @JsonValue('TERMINEE')
  done('Terminée');

  const PlanningTaskStatus(this.label);
  final String label;

  bool get isOpen => this != done;
}

enum PlanningTaskType {
  @JsonValue('SAISIE')
  entry('Saisie'),
  @JsonValue('COMPTAGE')
  count('Comptage'),
  @JsonValue('REVISION')
  review('Révision'),
  @JsonValue('RECEPTION')
  reception('Réception'),
  @JsonValue('PREPARATION')
  preparation('Préparation'),
  @JsonValue('AUTRE')
  other('Autre');

  const PlanningTaskType(this.label);
  final String label;

  String get wire => switch (this) {
    entry => 'SAISIE',
    count => 'COMPTAGE',
    review => 'REVISION',
    reception => 'RECEPTION',
    preparation => 'PREPARATION',
    other => 'AUTRE',
  };
}

/// Les jours (`scheduledFor`, `dueDate`) restent des CHAÎNES `AAAA-MM-JJ` :
/// ce sont des jours civils, pas des instants — les convertir en `DateTime`
/// les ferait glisser d'un jour selon le fuseau de l'appareil.
@freezed
abstract class PlanningTask with _$PlanningTask {
  const factory PlanningTask({
    required String id,
    required String title,
    required PlanningTaskType type,
    required PlanningTaskStatus status,
    required bool isLate,
    required String assignedToId,
    required String createdById,
    String? locationId,
    String? zone,
    String? description,
    required String scheduledFor,
    required String dueDate,
    DateTime? completedAt,
    String? comment,
    String? result,
    required DateTime updatedAt,
  }) = _PlanningTask;

  factory PlanningTask.fromJson(Map<String, dynamic> json) =>
      _$PlanningTaskFromJson(json);
}

@freezed
abstract class PlanningTaskPage with _$PlanningTaskPage {
  const factory PlanningTaskPage({
    required List<PlanningTask> data,
    required PageMeta meta,
  }) = _PlanningTaskPage;

  factory PlanningTaskPage.fromJson(Map<String, dynamic> json) =>
      _$PlanningTaskPageFromJson(json);
}
