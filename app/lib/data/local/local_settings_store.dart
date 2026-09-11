import 'app_database.dart';

/// Réglages locaux non secrets (thème, curseurs de delta sync…), rangés dans
/// la table Drift `LocalSettings`. Seul point d'accès à cette table : l'UI ne
/// parle jamais à Drift directement.
///
/// Rien de secret ici — les tokens vivent dans le stockage sécurisé de l'OS.
class LocalSettingsStore {
  LocalSettingsStore(this._db);

  final AppDatabase _db;

  Future<String?> read(String key) async {
    final row = await (_db.select(_db.localSettings)
          ..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> write(String key, String value) async {
    await _db
        .into(_db.localSettings)
        .insertOnConflictUpdate(
          LocalSettingsCompanion.insert(key: key, value: value),
        );
  }
}
