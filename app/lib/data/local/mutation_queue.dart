import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/app_config.dart';
import '../models/sync_models.dart';
import 'app_database.dart';

/// Accès à la file de mutations locale.
///
/// Règle d'or : une mutation n'est JAMAIS supprimée tant que le serveur n'a pas
/// rendu un verdict définitif, et son `clientMutationId` ne change jamais —
/// c'est ce qui garantit l'idempotence (docs/context.md §3).
class MutationQueue {
  MutationQueue(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _db;
  final Uuid _uuid;

  /// Enregistre une opération faite hors-ligne (ou en ligne : le chemin est le même).
  /// `authorUserId` : le compte connecté qui la saisit — elle ne partira
  /// qu'avec SA session (audit I2).
  ///
  /// `clientMutationId` : la clé de l'INTENTION quand l'opération a d'abord été
  /// tentée en ligne. Si cette tentative est arrivée au serveur mais que la
  /// réponse s'est perdue, la mutation portera la MÊME clé que l'entité déjà
  /// créée : le serveur la reconnaîtra au lieu de l'appliquer une seconde fois.
  Future<String> enqueue({
    required String authorUserId,
    required String deviceId,
    required String operationType,
    required Map<String, dynamic> payload,
    String? clientMutationId,
    DateTime? deviceTimestamp,
  }) async {
    // UUID v7 : trié dans le temps, donc l'ordre d'insertion reste lisible en base.
    final key = clientMutationId ?? _uuid.v7();
    final now = deviceTimestamp ?? DateTime.now().toUtc();

    // Clé d'intention déjà en file (deux envois simultanés du même geste) :
    // c'est la même opération, on ne la duplique pas et on ne casse pas.
    await _db
        .into(_db.pendingMutations)
        .insert(
          mode: InsertMode.insertOrIgnore,
          PendingMutationsCompanion.insert(
            clientMutationId: key,
            authorUserId: Value(authorUserId),
            deviceId: deviceId,
            operationType: operationType,
            payload: jsonEncode(payload),
            deviceTimestamp: now,
            createdAt: DateTime.now().toUtc(),
          ),
        );
    return key;
  }

  /// Mutations en attente d'UN auteur.
  Expression<bool> _pendingOf($PendingMutationsTable t, String authorUserId) =>
      t.status.equalsValue(LocalMutationStatus.enAttente) &
      t.authorUserId.equals(authorUserId);

  /// Prochain lot à envoyer : uniquement les mutations en attente DE CE COMPTE,
  /// dans l'ordre du timestamp appareil — l'ordre est ce qui garde la cohérence
  /// métier (un paiement ne doit pas partir avant la vente qu'il solde).
  /// Les mutations d'un autre compte restent en quarantaine sur l'appareil :
  /// elles partiront à la prochaine connexion de leur auteur.
  Future<List<PendingMutation>> nextBatch({
    required String authorUserId,
    int limit = AppConfig.maxMutationsPerBatch,
  }) {
    return (_db.select(_db.pendingMutations)
          ..where((t) => _pendingOf(t, authorUserId))
          ..orderBy([(t) => OrderingTerm.asc(t.deviceTimestamp)])
          ..limit(limit))
        .get();
  }

  Future<List<PendingMutation>> byStatus(LocalMutationStatus status) {
    return (_db.select(_db.pendingMutations)
          ..where((t) => t.status.equalsValue(status))
          ..orderBy([(t) => OrderingTerm.asc(t.deviceTimestamp)]))
        .get();
  }

  Selectable<int> _countWhere(Expression<bool> condition) {
    final count = _db.pendingMutations.clientMutationId.count();
    final query = _db.selectOnly(_db.pendingMutations)
      ..addColumns([count])
      ..where(condition);
    return query.map((row) => row.read(count) ?? 0);
  }

  /// Flux temps réel du nombre de mutations en attente de ce compte.
  /// L'indicateur de l'UI doit se mettre à jour tout seul après un `enqueue`
  /// ou un cycle de sync — un `Future` figerait la première valeur.
  Stream<int> watchPendingCount({required String authorUserId}) =>
      _countWhere(_pendingOf(_db.pendingMutations, authorUserId)).watchSingle();

  /// Mutations en attente laissées par un AUTRE compte (ou antérieures à la v2,
  /// auteur inconnu) : jamais envoyées avec cette session, mais signalées.
  Stream<int> watchForeignPendingCount({required String authorUserId}) {
    final t = _db.pendingMutations;
    return _countWhere(
      t.status.equalsValue(LocalMutationStatus.enAttente) &
          (t.authorUserId.isNull() | t.authorUserId.equals(authorUserId).not()),
    ).watchSingle();
  }

  /// Flux des mutations REJETÉES de ce compte — elles exigent une action de
  /// l'utilisateur (docs/context.md §6) : sans cet affichage, une vente refusée
  /// pour stock insuffisant disparaîtrait silencieusement et l'utilisateur la
  /// croirait faite.
  Stream<List<PendingMutation>> watchRejected({required String authorUserId}) {
    return (_db.select(_db.pendingMutations)
          ..where(
            (t) =>
                t.status.equalsValue(LocalMutationStatus.rejetee) &
                t.authorUserId.equals(authorUserId),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.deviceTimestamp)]))
        .watch();
  }

  Future<int> pendingCount({required String authorUserId}) =>
      _countWhere(_pendingOf(_db.pendingMutations, authorUserId)).getSingle();

  /// Convertit les lignes locales en corps de requête.
  ///
  /// Une ligne au JSON illisible est écartée et marquée rejetée : la laisser
  /// lever bloquerait TOUT le lot à chaque cycle, indéfiniment.
  Future<List<SyncMutationInput>> toInputs(List<PendingMutation> rows) async {
    final inputs = <SyncMutationInput>[];
    for (final row in rows) {
      try {
        inputs.add(
          SyncMutationInput(
            clientMutationId: row.clientMutationId,
            deviceId: row.deviceId,
            operationType: row.operationType,
            payload: jsonDecode(row.payload) as Map<String, dynamic>,
            deviceTimestamp: row.deviceTimestamp.toUtc().toIso8601String(),
          ),
        );
      } catch (error) {
        // `catch` LARGE volontairement : `jsonDecode` lève une FormatException,
        // mais un JSON valide qui n'est pas un objet (`[1,2]`, `3`) lève un
        // TypeError sur le cast. N'attraper que FormatException laisserait ce
        // second cas rebloquer tout le lot à chaque cycle — le poison pill
        // qu'on cherche précisément à supprimer.
        await applyResult(
          SyncResult(
            clientMutationId: row.clientMutationId,
            status: SyncStatus.rejetee,
            code: 'LOCAL_PAYLOAD_CORROMPU',
            reason: 'Données locales illisibles : $error',
          ),
        );
      }
    }
    return inputs;
  }

  /// Applique le verdict du serveur.
  ///
  /// - `CONFIRMEE` → la mutation quitte la file (l'entité vit désormais côté serveur) ;
  /// - `REJETEE`  → conservée, marquée échouée : elle exige une décision de l'utilisateur,
  ///   la supprimer silencieusement effacerait une opération qu'il croit faite ;
  /// - `NON_TRAITEE` → laissée en attente, elle repartira au prochain envoi.
  Future<void> applyResult(SyncResult result) async {
    final target = _db.update(_db.pendingMutations)
      ..where((t) => t.clientMutationId.equals(result.clientMutationId));

    switch (result.status) {
      case SyncStatus.confirmee:
        await (_db.delete(
              _db.pendingMutations,
            )..where((t) => t.clientMutationId.equals(result.clientMutationId)))
            .go();
      case SyncStatus.rejetee:
        await target.write(
          PendingMutationsCompanion(
            status: Value(LocalMutationStatus.rejetee),
            rejectionCode: Value(result.code),
            rejectionReason: Value(result.reason),
            lastAttemptAt: Value(DateTime.now().toUtc()),
          ),
        );
      case SyncStatus.nonTraitee:
        await target.write(
          PendingMutationsCompanion(
            status: const Value(LocalMutationStatus.enAttente),
            lastAttemptAt: Value(DateTime.now().toUtc()),
          ),
        );
    }
  }

  /// Incrémente le compteur de tentatives des mutations envoyées.
  Future<void> markAttempted(List<String> clientMutationIds) async {
    if (clientMutationIds.isEmpty) return;
    await _db.customUpdate(
      'UPDATE pending_mutations SET attempt_count = attempt_count + 1, '
      'last_attempt_at = ? WHERE client_mutation_id IN '
      '(${List.filled(clientMutationIds.length, '?').join(',')})',
      variables: [
        Variable.withDateTime(DateTime.now().toUtc()),
        ...clientMutationIds.map(Variable.withString),
      ],
      updates: {_db.pendingMutations},
    );
  }

  /// L'utilisateur abandonne une mutation rejetée.
  /// Corriger = créer une NOUVELLE mutation, jamais réutiliser l'identifiant rejeté.
  /// Seule une mutation REJETÉE de ce compte s'abandonne : une mutation en
  /// attente supprimée serait une opération perdue que l'utilisateur croit faite.
  Future<void> discard(
    String clientMutationId, {
    required String authorUserId,
  }) async {
    await (_db.delete(_db.pendingMutations)..where(
          (t) =>
              t.clientMutationId.equals(clientMutationId) &
              t.status.equalsValue(LocalMutationStatus.rejetee) &
              t.authorUserId.equals(authorUserId),
        ))
        .go();
  }

  /// L'appareil est-il resté trop longtemps sans synchroniser ?
  /// Au-delà, le stock local est trop faux pour autoriser de nouvelles ventes
  /// (docs/context.md § Bornes de données offline).
  Future<bool> isTooStale({required String authorUserId}) async {
    final oldest =
        await (_db.select(_db.pendingMutations)
              ..where((t) => _pendingOf(t, authorUserId))
              ..orderBy([(t) => OrderingTerm.asc(t.deviceTimestamp)])
              ..limit(1))
            .getSingleOrNull();
    if (oldest == null) return false;

    final age = DateTime.now().toUtc().difference(oldest.deviceTimestamp);
    final count = await pendingCount(authorUserId: authorUserId);
    return age > AppConfig.maxOfflineDuration ||
        count >= AppConfig.maxPendingMutations;
  }
}
