import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'error/api_exception.dart';
import 'file_export.dart';
import 'providers.dart';

/// Import Excel/CSV (spec §8quinquies) : l'app choisit le fichier et l'envoie,
/// le SERVEUR vérifie tout — à blanc d'abord, puis tout ou rien.
enum ImportKind {
  products('produits'),
  customers('clients'),
  suppliers('fournisseurs');

  const ImportKind(this.label);

  /// « produits », « clients »… pour les messages.
  final String label;
}

class ImportLineError {
  const ImportLineError(this.line, this.message);

  final int line;
  final String message;
}

/// Compte rendu du serveur : lignes lues, créées, erreurs par ligne.
class ImportReport {
  const ImportReport({
    required this.dryRun,
    required this.total,
    required this.created,
    required this.errors,
    this.ignored = const [],
  });

  factory ImportReport.fromJson(Map<String, dynamic> json) => ImportReport(
    dryRun: json['dryRun'] as bool,
    total: json['total'] as int,
    created: json['created'] as int,
    errors: [
      for (final e in json['errors'] as List<dynamic>)
        ImportLineError(
          (e as Map<String, dynamic>)['line'] as int,
          e['message'] as String,
        ),
    ],
    ignored: [
      for (final c in json['ignored'] as List<dynamic>? ?? const []) '$c',
    ],
  );

  final bool dryRun;
  final int total;
  final int created;
  final List<ImportLineError> errors;

  /// Colonnes de l'en-tête que l'import ne lit pas (faute de frappe…).
  final List<String> ignored;

  int get ready => total - errors.length;
}

/// Taille maximale d'un fichier d'import (la même borne côté serveur).
const maxImportBytes = 2 * 1024 * 1024;

/// Délai de réponse d'un import appliqué : jusqu'à 1 000 fiches créées d'un
/// bloc (le serveur s'accorde 120 s).
const importApplyTimeout = Duration(seconds: 150);

/// Client des routes d'import. Remplaçable en test.
class ImportApi {
  ImportApi(this._dio);

  final Dio _dio;

  /// Envoie un fichier d'import. `dryRun` : vérification seule, rien d'écrit.
  Future<ImportReport> send(
    ImportKind kind,
    Uint8List bytes,
    String filename, {
    required bool dryRun,
  }) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/imports/${kind.name}',
        queryParameters: {'dryRun': dryRun},
        options: dryRun ? null : Options(receiveTimeout: importApplyTimeout),
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(bytes, filename: filename),
        }),
      );
      return ImportReport.fromJson(response.data!);
    });
  }

  /// Modèle à remplir, rendu par le serveur (même garde que l'import).
  Future<ExportedFile> template(ImportKind kind, ExportFormat format) =>
      fetchExport(_dio, '/imports/${kind.name}/template', format);
}

final importApiProvider = Provider<ImportApi>(
  (ref) => ImportApi(ref.watch(dioClientProvider).dio),
);

/// Choix d'un fichier Excel ou CSV sur le poste. Remplaçable en test.
final pickImportFileProvider =
    Provider<Future<({Uint8List bytes, String name})?> Function()>(
      (ref) => () async {
        final file = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(label: 'Excel ou CSV', extensions: ['xlsx', 'csv']),
          ],
        );
        if (file == null) return null;
        return (bytes: await file.readAsBytes(), name: file.name);
      },
    );
