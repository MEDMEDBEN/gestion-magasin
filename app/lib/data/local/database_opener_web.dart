import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

/// Navigateur : SQLite compilé en WebAssembly, enregistré dans le stockage du
/// site (OPFS ou IndexedDB, choisi par drift selon le navigateur). La file des
/// ventes hors ligne survit donc à un rechargement de la page.
/// `sqlite3.wasm` et `drift_worker.js` sont servis depuis `web/` ; leurs
/// versions suivent celles de `sqlite3` et `drift` (pubspec.lock).
QueryExecutor openLocalDatabase() {
  return DatabaseConnection.delayed(
    Future(() async {
      final result = await WasmDatabase.open(
        databaseName: 'gestion_magasin',
        sqlite3Uri: Uri.parse('sqlite3.wasm'),
        driftWorkerUri: Uri.parse('drift_worker.js'),
      );
      return result.resolvedExecutor;
    }),
  );
}

QueryExecutor openMemoryDatabase() =>
    throw UnsupportedError('Base en mémoire : tests uniquement (VM)');
