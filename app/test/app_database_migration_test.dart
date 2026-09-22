import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/data/local/document_cache.dart';
import 'package:gestion_magasin/data/local/mutation_queue.dart';

/// Schéma v2 (audit I2) : une base installée en v1 doit migrer SANS perte, et
/// ses mutations sans auteur ne doivent partir avec la session de personne.
void main() {
  test(
    'une base v1 migre en v2 : colonne auteur ajoutée, lignes existantes en quarantaine',
    () async {
      final executor = NativeDatabase.memory(
        setup: (raw) {
          raw.execute('''
          CREATE TABLE pending_mutations (
            client_mutation_id TEXT NOT NULL PRIMARY KEY,
            device_id TEXT NOT NULL,
            operation_type TEXT NOT NULL,
            payload TEXT NOT NULL,
            device_timestamp INTEGER NOT NULL,
            status INTEGER NOT NULL DEFAULT 0,
            rejection_code TEXT NULL,
            rejection_reason TEXT NULL,
            entity_id TEXT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_attempt_at INTEGER NULL,
            created_at INTEGER NOT NULL
          )''');
          raw.execute(
            'CREATE TABLE local_settings (key TEXT NOT NULL PRIMARY KEY, '
            'value TEXT NOT NULL)',
          );
          raw.execute(
            "INSERT INTO pending_mutations (client_mutation_id, device_id, "
            "operation_type, payload, device_timestamp, created_at) "
            "VALUES ('mutation-v1', 'poste', 'MANUAL', '{}', 1788940800, 1788940800)",
          );
          raw.execute('PRAGMA user_version = 1');
        },
      );
      final db = AppDatabase(executor);
      addTearDown(db.close);
      final queue = MutationQueue(db);

      // La ligne v1 a survécu, sans auteur connu : elle n'est envoyée par
      // PERSONNE, mais elle est signalée à tout compte connecté.
      expect(await queue.nextBatch(authorUserId: 'compte-a'), isEmpty);
      expect(
        await queue.watchForeignPendingCount(authorUserId: 'compte-a').first,
        1,
      );

      // Et la nouvelle colonne est bien utilisable.
      await queue.enqueue(
        authorUserId: 'compte-a',
        deviceId: 'poste',
        operationType: 'MANUAL',
        payload: const {},
      );
      expect(await queue.pendingCount(authorUserId: 'compte-a'), 1);
    },
  );

  test('une base v4 migre en v5 : la table des documents hors-ligne apparaît, '
      'la file en attente survit', () async {
    final executor = NativeDatabase.memory(
      setup: (raw) {
        // Schéma v4 : file AVEC auteur, réglages, catalogue AVEC updatedAt.
        raw.execute('''
          CREATE TABLE pending_mutations (
            client_mutation_id TEXT NOT NULL PRIMARY KEY,
            author_user_id TEXT NULL,
            device_id TEXT NOT NULL,
            operation_type TEXT NOT NULL,
            payload TEXT NOT NULL,
            device_timestamp INTEGER NOT NULL,
            status INTEGER NOT NULL DEFAULT 0,
            rejection_code TEXT NULL,
            rejection_reason TEXT NULL,
            entity_id TEXT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_attempt_at INTEGER NULL,
            created_at INTEGER NOT NULL
          )''');
        raw.execute(
          'CREATE TABLE local_settings (key TEXT NOT NULL PRIMARY KEY, '
          'value TEXT NOT NULL)',
        );
        raw.execute('''
          CREATE TABLE catalog_entries (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            label TEXT NOT NULL,
            search_text TEXT NOT NULL,
            parent_id TEXT NULL,
            is_active INTEGER NOT NULL,
            json TEXT NOT NULL,
            updated_at INTEGER NULL,
            PRIMARY KEY (kind, id)
          )''');
        raw.execute(
          "INSERT INTO pending_mutations (client_mutation_id, author_user_id, "
          "device_id, operation_type, payload, device_timestamp, created_at) "
          "VALUES ('mutation-v4', 'compte-a', 'poste', 'SALE', '{}', "
          "1788940800, 1788940800)",
        );
        raw.execute('PRAGMA user_version = 4');
      },
    );
    final db = AppDatabase(executor);
    addTearDown(db.close);

    // La vente en attente n'est pas perdue par la migration.
    expect(await MutationQueue(db).pendingCount(authorUserId: 'compte-a'), 1);

    // Et la copie hors-ligne est utilisable tout de suite.
    final cache = DocumentCache(db);
    await cache.save('compte-a', DocumentKind.transfer, [
      {'id': 't1', 'number': 'TRF-2026-00001'},
    ]);
    final kept = await cache.read('compte-a', DocumentKind.transfer);
    expect(kept.documents.single['number'], 'TRF-2026-00001');
    expect(kept.cachedAt, isNotNull);
  });
}
