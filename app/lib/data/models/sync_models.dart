import 'package:freezed_annotation/freezed_annotation.dart';

part 'sync_models.freezed.dart';
part 'sync_models.g.dart';

/// Verdict du serveur pour une mutation (miroir du contrat `POST /sync`).
///
/// Seuls `CONFIRMEE` et `REJETEE` sont MÉMORISÉS côté serveur et donc définitifs.
/// `NON_TRAITEE` ne l'est jamais : la mutation reste dans la file et sera renvoyée
/// (docs/context.md, journal du 2026-09-09).
enum SyncStatus {
  @JsonValue('CONFIRMEE')
  confirmee,
  @JsonValue('REJETEE')
  rejetee,
  @JsonValue('NON_TRAITEE')
  nonTraitee,
}

/// Une mutation envoyée au serveur.
/// `clientMutationId` est un UUID généré À LA SAISIE : c'est la clé d'idempotence,
/// elle ne change JAMAIS entre deux tentatives d'envoi.
@freezed
abstract class SyncMutationInput with _$SyncMutationInput {
  const factory SyncMutationInput({
    required String clientMutationId,
    required String deviceId,
    required String operationType,
    required Map<String, dynamic> payload,
    required String deviceTimestamp,
  }) = _SyncMutationInput;

  factory SyncMutationInput.fromJson(Map<String, dynamic> json) =>
      _$SyncMutationInputFromJson(json);
}

/// Verdict rendu pour une mutation.
@freezed
abstract class SyncResult with _$SyncResult {
  const factory SyncResult({
    required String clientMutationId,
    required SyncStatus status,
    String? entityId,
    String? code,
    String? reason,
    Map<String, dynamic>? serverState,
    @Default(false) bool alreadyProcessed,
  }) = _SyncResult;

  factory SyncResult.fromJson(Map<String, dynamic> json) =>
      _$SyncResultFromJson(json);
}

@freezed
abstract class SyncBatchResult with _$SyncBatchResult {
  const factory SyncBatchResult({
    required String serverTime,
    required List<SyncResult> results,
  }) = _SyncBatchResult;

  factory SyncBatchResult.fromJson(Map<String, dynamic> json) =>
      _$SyncBatchResultFromJson(json);
}
