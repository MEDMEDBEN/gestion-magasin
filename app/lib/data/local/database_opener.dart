// Ouverture de la base locale selon la cible : fichier SQLite (Windows,
// Android) ou stockage du navigateur (version web, 2026-10-06).
export 'database_opener_native.dart'
    if (dart.library.js_interop) 'database_opener_web.dart';
