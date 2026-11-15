import 'package:drift/drift.dart';

import 'app_database.dart';

/// Réinitialisation du POSTE (demande MEDMEDBEN du 2026-11-15 : « vider
/// l'app définitivement » avant de la confier au vrai utilisateur) : toute la
/// base locale est effacée — catalogue, documents gardés, réglages, file.
///
/// Jamais tant qu'une opération hors ligne attend : ce serait perdre une
/// vente. Renvoie le nombre d'opérations en attente (0 = effacé).
Future<int> resetDeviceData(AppDatabase db) => db.transaction(() async {
  // Compté DANS la transaction : aucune vente ne se glisse entre le
  // contrôle et l'effacement.
  final waiting =
      await (db.selectOnly(db.pendingMutations)
            ..addColumns([db.pendingMutations.clientMutationId.count()])
            ..where(
              db.pendingMutations.status.equalsValue(
                LocalMutationStatus.enAttente,
              ),
            ))
          .map((row) => row.read(db.pendingMutations.clientMutationId.count())!)
          .getSingle();
  if (waiting > 0) return waiting;
  for (final table in db.allTables) {
    await db.delete(table).go();
  }
  return 0;
});
