import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../data/models/page_meta.dart';

part 'problem_models.freezed.dart';
part 'problem_models.g.dart';

/// Nature du problème constaté (spec §26).
enum ProblemCategory {
  @JsonValue('STOCK_INCORRECT')
  wrongStock('Stock incorrect'),
  @JsonValue('PRODUIT_MANQUANT')
  missingProduct('Produit manquant'),
  @JsonValue('PRODUIT_ENDOMMAGE')
  damagedProduct('Produit endommagé'),
  @JsonValue('PROBLEME_INFORMATIQUE')
  software('Problème informatique'),
  @JsonValue('PROBLEME_MATERIEL')
  hardware('Problème matériel'),
  @JsonValue('AUTRE')
  other('Autre'),

  /// Catégorie inconnue de CETTE version : le signalement reste lisible.
  unknown('Autre');

  const ProblemCategory(this.label);
  final String label;

  String get wire => switch (this) {
    ProblemCategory.wrongStock => 'STOCK_INCORRECT',
    ProblemCategory.missingProduct => 'PRODUIT_MANQUANT',
    ProblemCategory.damagedProduct => 'PRODUIT_ENDOMMAGE',
    ProblemCategory.software => 'PROBLEME_INFORMATIQUE',
    ProblemCategory.hardware => 'PROBLEME_MATERIEL',
    ProblemCategory.other || ProblemCategory.unknown => 'AUTRE',
  };
}

/// `OUVERT → (EN_COURS) → RESOLU → FERME`. `EN_COURS` est facultatif ; seul
/// `FERME` exige d'être passé par `RESOLU` (mêmes transitions que le serveur).
enum ProblemStatus {
  @JsonValue('OUVERT')
  open('Ouvert'),
  @JsonValue('EN_COURS')
  inProgress('En cours'),
  @JsonValue('RESOLU')
  resolved('Résolu'),
  @JsonValue('FERME')
  closed('Fermé'),

  /// Statut inconnu de CETTE version. Aucun `@JsonValue` : il n'existe dans
  /// aucun enum serveur, c'est `unknownEnumValue` qui y mène.
  unknown('—');

  const ProblemStatus(this.label);
  final String label;

  /// `null` pour `unknown` : un statut que CETTE version ne connaît pas ne doit
  /// pas être renvoyé au serveur sous le nom d'un autre — filtrer dessus
  /// rapporterait les mauvais signalements.
  String? get wire => switch (this) {
    ProblemStatus.open => 'OUVERT',
    ProblemStatus.inProgress => 'EN_COURS',
    ProblemStatus.resolved => 'RESOLU',
    ProblemStatus.closed => 'FERME',
    ProblemStatus.unknown => null,
  };
}

enum ProblemPriority {
  @JsonValue('BASSE')
  low('Basse'),
  @JsonValue('NORMALE')
  normal('Normale'),
  @JsonValue('HAUTE')
  high('Haute'),
  @JsonValue('URGENTE')
  urgent('Urgente');

  const ProblemPriority(this.label);
  final String label;

  String get wire => switch (this) {
    ProblemPriority.low => 'BASSE',
    ProblemPriority.normal => 'NORMALE',
    ProblemPriority.high => 'HAUTE',
    ProblemPriority.urgent => 'URGENTE',
  };
}

@freezed
abstract class Problem with _$Problem {
  const factory Problem({
    required String id,
    required String title,
    @JsonKey(unknownEnumValue: ProblemCategory.unknown)
    required ProblemCategory category,
    required String description,
    @JsonKey(unknownEnumValue: ProblemPriority.normal)
    required ProblemPriority priority,
    @JsonKey(unknownEnumValue: ProblemStatus.unknown)
    required ProblemStatus status,
    @Default(false) bool hasPhoto,
    String? productId,
    String? productName,
    String? locationId,
    String? locationName,
    required String reportedById,
    required String reportedByName,
    String? assignedToId,
    String? assignedToName,
    String? resolution,
    DateTime? resolvedAt,
    DateTime? closedAt,
    required DateTime createdAt,
  }) = _Problem;

  const Problem._();

  /// Clos : plus aucune action possible (règle 7 — on en rouvre un nouveau).
  bool get isClosed =>
      status == ProblemStatus.resolved || status == ProblemStatus.closed;

  factory Problem.fromJson(Map<String, dynamic> json) =>
      _$ProblemFromJson(json);
}

@freezed
abstract class ProblemPage with _$ProblemPage {
  const factory ProblemPage({
    required List<Problem> data,
    required PageMeta meta,
  }) = _ProblemPage;

  factory ProblemPage.fromJson(Map<String, dynamic> json) =>
      _$ProblemPageFromJson(json);
}
