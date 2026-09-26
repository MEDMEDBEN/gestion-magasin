import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'error/api_exception.dart';

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
  try {
    final response = await dio.get<List<int>>(
      path,
      queryParameters: {...query, 'format': format.name},
      options: Options(responseType: ResponseType.bytes),
    );
    return ExportedFile(
      Uint8List.fromList(response.data!),
      exportFilename(
        response.headers.value('content-disposition'),
        fallback: 'export.${format.name}',
      ),
    );
  } on DioException catch (error) {
    // En `bytes`, l'erreur arrive AUSSI en octets : sans ce décodage, un refus
    // métier (export trop volumineux) s'afficherait « Erreur inattendue ».
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

/// Nom annoncé par le serveur (`Content-Disposition`), réduit à un nom de
/// fichier sans chemin : il finit sur le disque.
String exportFilename(String? disposition, {required String fallback}) {
  final name = RegExp(r'filename="([^"]+)"').firstMatch(disposition ?? '');
  final cleaned = name?.group(1)?.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return cleaned == null || cleaned.isEmpty || cleaned.startsWith('.')
      ? fallback
      : cleaned;
}

/// Enregistre un export dans « Téléchargements » (à défaut, les documents de
/// l'app) SANS écraser un fichier existant — un export précédent peut être
/// ouvert dans le tableur. Rend le chemin écrit. Remplaçable en test.
final saveExportProvider = Provider<Future<String> Function(ExportedFile file)>(
  (ref) => (file) async {
    Directory? directory;
    try {
      directory = await getDownloadsDirectory();
    } on UnsupportedError {
      directory = null;
    }
    directory ??= await getApplicationDocumentsDirectory();

    final base = p.basenameWithoutExtension(file.filename);
    final extension = p.extension(file.filename);
    var target = File(p.join(directory.path, file.filename));
    for (var n = 2; await target.exists(); n++) {
      target = File(p.join(directory.path, '$base ($n)$extension'));
    }
    await target.writeAsBytes(file.bytes, flush: true);
    return target.path;
  },
);
