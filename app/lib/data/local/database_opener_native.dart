import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Fichier SQLite dans le dossier de l'application.
QueryExecutor openLocalDatabase() {
  return LazyDatabase(() async {
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, 'gestion_magasin.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

/// Base en mémoire pour les tests — aucun fichier, aucun plugin natif.
QueryExecutor openMemoryDatabase() => NativeDatabase.memory();
