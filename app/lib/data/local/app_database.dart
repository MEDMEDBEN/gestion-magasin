import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

/// Statut LOCAL d'une mutation (docs/context.md §2).
/// Distinct du verdict serveur : `enAttente` couvre aussi bien « jamais envoyée »
/// que « envoyée mais revenue NON_TRAITEE ».
enum LocalMutationStatus { enAttente, confirmee, rejetee }

/// File de mutations hors-ligne — miroir du corps attendu par `POST /api/sync`.
///
/// `clientMutationId` est la clé d'idempotence : générée à la SAISIE, jamais
/// régénérée à un renvoi, sinon le serveur appliquerait l'opération deux fois.
class PendingMutations extends Table {
  TextColumn get clientMutationId => text()();

  /// Compte qui a saisi l'opération (schéma v2 — audit I2). Le serveur attribue
  /// une mutation au porteur du token qui l'envoie : sur un poste partagé, sans
  /// cette colonne, les pertes laissées en attente par le magasinier partiraient
  /// avec le token du vendeur suivant (rejetées), ou une ligne forgée par un
  /// vendeur serait exécutée avec les droits de l'admin connecté après lui.
  /// `null` = ligne antérieure à la v2 : auteur inconnu, jamais envoyée.
  TextColumn get authorUserId => text().nullable()();

  TextColumn get deviceId => text()();
  TextColumn get operationType => text()();

  /// Payload JSON sérialisé, tel qu'il partira au serveur.
  TextColumn get payload => text()();

  /// Horodatage de l'APPAREIL : donne l'ordre de rejeu du lot.
  DateTimeColumn get deviceTimestamp => dateTime()();

  IntColumn get status => intEnum<LocalMutationStatus>()
      .withDefault(Constant(LocalMutationStatus.enAttente.index))();

  /// Code métier stable du rejet — l'UI se branche dessus, jamais sur le motif.
  TextColumn get rejectionCode => text().nullable()();
  TextColumn get rejectionReason => text().nullable()();

  /// Id de l'entité créée côté serveur, une fois la mutation confirmée.
  TextColumn get entityId => text().nullable()();

  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {clientMutationId};
}

/// Curseurs de delta sync et réglages locaux.
class LocalSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [PendingMutations, LocalSettings])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  /// Base en mémoire pour les tests — aucun fichier, aucun plugin natif.
  AppDatabase.forTesting() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(pendingMutations, pendingMutations.authorUserId);
          }
        },
      );

  static QueryExecutor _open() {
    return LazyDatabase(() async {
      final directory = await getApplicationSupportDirectory();
      final file = File(p.join(directory.path, 'gestion_magasin.sqlite'));
      return NativeDatabase.createInBackground(file);
    });
  }
}
