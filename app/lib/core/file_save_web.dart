import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'file_export.dart';

/// Navigateur : le fichier part en téléchargement (dossier choisi par le
/// navigateur, qui gère lui-même les doublons). Rend le nom du fichier.
Future<String> saveExportFile(ExportedFile file) async {
  final blob = web.Blob([file.bytes.toJS].toJS);
  final url = web.URL.createObjectURL(blob);
  web.HTMLAnchorElement()
    ..href = url
    ..download = file.filename
    ..click();
  // Libéré après coup : Safari lit l'URL APRÈS le clic.
  Future.delayed(
    const Duration(minutes: 1),
    () => web.URL.revokeObjectURL(url),
  );
  return file.filename;
}
