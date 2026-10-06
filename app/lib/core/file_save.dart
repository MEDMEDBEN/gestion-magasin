// Enregistrement d'un export selon la cible : fichier sur le disque (app
// installée) ou téléchargement du navigateur (version web, 2026-10-06).
export 'file_save_io.dart' if (dart.library.js_interop) 'file_save_web.dart';
