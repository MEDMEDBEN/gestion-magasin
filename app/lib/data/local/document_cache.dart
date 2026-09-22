import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/config/app_config.dart';
import 'app_database.dart';

/// Types de documents gardés pour ouvrir un écran sans réseau (P1 n°14).
///
/// PAS de commande fournisseur : elle porte les prix d'achat et le fournisseur,
/// que `docs/permissions.md` interdit d'écrire sur le disque d'un poste partagé.
/// Une réception se saisit quand même hors-ligne : c'est l'écran qui doit avoir
/// été ouvert avant la coupure.
enum DocumentKind { transfer, inventory }

/// Documents de travail du COMPTE CONNECTÉ, gardés sur l'appareil.
///
/// Une liste lue en ligne remplace la précédente ; sans réseau, l'écran ouvre
/// la dernière connue en le disant. Rien n'est jamais écrit d'ici : les
/// écritures passent par la file de mutations, le serveur reste juge.
class DocumentCache {
  DocumentCache(this._db);

  final AppDatabase _db;

  /// Au-delà, la copie n'est plus proposée : un magasinier ne travaille pas sur
  /// une liste vieille de plusieurs jours (docs/context.md, bornes offline).
  static const maxAge = AppConfig.maxOfflineDuration;

  /// Remplace la liste connue de ce type pour ce compte.
  ///
  /// L'horodatage est gardé À PART : une liste VIDE (rien à faire aujourd'hui)
  /// est un état normal, qui doit s'ouvrir hors ligne comme les autres — sans
  /// cela, l'écran retomberait en erreur le jour où il n'y a rien.
  /// L'ORDRE du serveur est conservé (`rank`) : le plus récent d'abord.
  /// Une liste dont un document n'a pas d'`id` n'est pas gardée : une liste de
  /// travail amputée en silence est pire qu'une absence de copie.
  Future<void> save(
    String accountId,
    DocumentKind kind,
    List<Map<String, dynamic>> documents, {
    DateTime? at,
  }) async {
    final ids = [
      for (final document in documents)
        if (document['id'] case final String id) id,
    ];
    if (ids.length != documents.length) return;
    final cachedAt = at ?? DateTime.now().toUtc();
    await _db.transaction(() async {
      await _deleteOf(accountId, kind);
      await _db.batch((batch) {
        batch.insertAll(_db.cachedDocuments, [
          for (var i = 0; i < documents.length; i++)
            CachedDocumentsCompanion.insert(
              accountId: accountId,
              kind: kind.name,
              id: ids[i],
              rank: i,
              json: jsonEncode(documents[i]),
            ),
        ]);
      });
      await _db
          .into(_db.localSettings)
          .insertOnConflictUpdate(
            LocalSettingsCompanion.insert(
              key: _stampKey(accountId, kind),
              value: cachedAt.toIso8601String(),
            ),
          );
    });
  }

  /// Dernière liste connue (dans l'ordre du serveur). `cachedAt` nul : rien n'a
  /// jamais été gardé — ou la copie est trop vieille, et elle vient d'être
  /// effacée. Une liste VIDE avec une date est une vraie réponse.
  Future<({List<Map<String, dynamic>> documents, DateTime? cachedAt})> read(
    String accountId,
    DocumentKind kind,
  ) async {
    final stamp =
        await (_db.select(_db.localSettings)
              ..where((t) => t.key.equals(_stampKey(accountId, kind))))
            .getSingleOrNull();
    final cachedAt = stamp == null ? null : DateTime.tryParse(stamp.value);
    if (cachedAt == null) {
      return (documents: const <Map<String, dynamic>>[], cachedAt: null);
    }
    if (DateTime.now().toUtc().difference(cachedAt) > maxAge) {
      await clear(accountId);
      return (documents: const <Map<String, dynamic>>[], cachedAt: null);
    }
    final rows =
        await (_db.select(_db.cachedDocuments)
              ..where(
                (t) => t.accountId.equals(accountId) & t.kind.equals(kind.name),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.rank)]))
            .get();
    return (
      documents: [
        for (final row in rows) jsonDecode(row.json) as Map<String, dynamic>,
      ],
      cachedAt: cachedAt,
    );
  }

  /// Efface tout ce qui est gardé pour un compte (déconnexion) : les documents
  /// de travail ne survivent pas à la session sur un poste partagé.
  Future<void> clear(String accountId) async {
    await (_db.delete(
      _db.cachedDocuments,
    )..where((t) => t.accountId.equals(accountId))).go();
    for (final kind in DocumentKind.values) {
      await (_db.delete(
        _db.localSettings,
      )..where((t) => t.key.equals(_stampKey(accountId, kind)))).go();
    }
  }

  Future<void> _deleteOf(String accountId, DocumentKind kind) =>
      (_db.delete(_db.cachedDocuments)..where(
            (t) => t.accountId.equals(accountId) & t.kind.equals(kind.name),
          ))
          .go();

  static String _stampKey(String accountId, DocumentKind kind) =>
      'documents.$accountId.${kind.name}';
}
