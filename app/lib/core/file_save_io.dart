import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'file_export.dart';

/// Enregistre un export dans « Téléchargements » (à défaut, les documents de
/// l'app) SANS écraser un fichier existant — un export précédent peut être
/// ouvert dans le tableur. Rend le chemin écrit. Remplaçable en test.
Future<String> saveExportFile(ExportedFile file) async {
  Directory? directory;
  try {
    directory = await getDownloadsDirectory();
  } on UnsupportedError {
    directory = null;
  }
  directory ??= await getApplicationDocumentsDirectory();
  return saveWithoutOverwrite(directory, file);
}

/// Écrit `file` dans `directory` sans jamais écraser : « x.csv », puis
/// « x (2).csv », « x (3).csv »… Rend le chemin écrit.
Future<String> saveWithoutOverwrite(
  Directory directory,
  ExportedFile file,
) async {
  final base = p.basenameWithoutExtension(file.filename);
  final extension = p.extension(file.filename);
  var target = File(p.join(directory.path, file.filename));
  for (var n = 2; await target.exists(); n++) {
    target = File(p.join(directory.path, '$base ($n)$extension'));
  }
  await target.writeAsBytes(file.bytes, flush: true);
  return target.path;
}
