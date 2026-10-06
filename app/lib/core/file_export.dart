import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'error/api_exception.dart';
import 'file_save.dart';

export 'file_save.dart';

/// Exports de fichiers (spec §8quinquies). Le fichier est RENDU PAR LE SERVEUR
/// (rendu identique pour tous) ; l'app le télécharge et l'enregistre, rien de
/// plus. Le serveur applique aux exports les gardes de l'écran exporté.
enum ExportFormat {
  xlsx('Excel'),
  csv('CSV'),
  pdf('PDF');

  const ExportFormat(this.label);

  final String label;
}

class ExportedFile {
  const ExportedFile(this.bytes, this.filename);

  final Uint8List bytes;
  final String filename;
}

/// Télécharge une route d'export. Appelé par le client d'API de la feature.
Future<ExportedFile> fetchExport(
  Dio dio,
  String path,
  ExportFormat format, {
  Map<String, dynamic> query = const {},
}) async {
  final response = await guardBytes(
    () => dio.get<List<int>>(
      path,
      queryParameters: {...query, 'format': format.name},
      options: Options(responseType: ResponseType.bytes),
    ),
  );
  return ExportedFile(
    Uint8List.fromList(response.data!),
    exportFilename(
      response.headers.value('content-disposition'),
      fallback: 'export.${format.name}',
    ),
  );
}

/// Appel qui rend un FICHIER (export, PDF, étiquettes). En `bytes`, l'erreur
/// arrive AUSSI en octets : sans ce décodage, un refus métier (export trop
/// volumineux, produit sans prix) s'afficherait « Erreur inattendue ».
Future<Response<List<int>>> guardBytes(
  Future<Response<List<int>>> Function() call,
) async {
  try {
    return await call();
  } on DioException catch (error) {
    final data = error.response?.data;
    if (data is List<int>) {
      try {
        error.response!.data = jsonDecode(utf8.decode(data));
      } on FormatException {
        // Corps illisible : l'erreur générique suffit.
      }
    }
    throw ApiException.fromDio(error);
  }
}

/// Les `days` derniers jours civils, aujourd'hui compris (`to` inclus côté
/// serveur) : la fenêtre des exports d'historique proposés à l'écran.
({String from, String to}) recentWindow(int days, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final day = DateTime(today.year, today.month, today.day);
  String iso(DateTime value) => value.toIso8601String().substring(0, 10);
  return (from: iso(day.subtract(Duration(days: days - 1))), to: iso(day));
}

/// Nom annoncé par le serveur (`Content-Disposition`), réduit à un nom de
/// fichier sans chemin : il finit sur le disque.
String exportFilename(String? disposition, {required String fallback}) {
  final name = RegExp(r'filename="([^"]+)"').firstMatch(disposition ?? '');
  final cleaned = name
      ?.group(1)
      // Séparateurs de chemin, caractères interdits et de contrôle.
      ?.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      // Windows ignore les points et espaces finaux : « a.csv. » = « a.csv ».
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (cleaned == null || cleaned.isEmpty || cleaned.startsWith('.')) {
    return fallback;
  }
  // Noms réservés de Windows (CON, NUL, COM1…) : écrire dessus échoue ou
  // vise un périphérique.
  final base = p.basenameWithoutExtension(cleaned).toLowerCase();
  if (RegExp(r'^(con|prn|aux|nul|com\d|lpt\d)$').hasMatch(base)) {
    return fallback;
  }
  return cleaned;
}

/// Enregistre un export sur ce poste (disque, ou téléchargement du
/// navigateur). Rend où il est. Remplaçable en test.
final saveExportProvider = Provider<Future<String> Function(ExportedFile file)>(
  (ref) => saveExportFile,
);
