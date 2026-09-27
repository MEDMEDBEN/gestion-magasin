import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/api_exception.dart';
import '../../core/file_export.dart';
import '../../core/file_import.dart';

/// « Importer » : télécharger le modèle, puis envoyer le fichier rempli. Le
/// serveur le vérifie d'abord À BLANC (rien n'est écrit) ; l'écran montre les
/// lignes prêtes et chaque erreur avec sa ligne ; l'import ne part qu'avec un
/// fichier sans erreur, et crée tout d'un bloc — ou rien.
class ImportButton extends ConsumerStatefulWidget {
  const ImportButton({required this.kind, this.onImported, super.key});

  final ImportKind kind;

  /// Après un import réussi : relire la liste affichée.
  final VoidCallback? onImported;

  @override
  ConsumerState<ImportButton> createState() => _ImportButtonState();
}

class _ImportButtonState extends ConsumerState<ImportButton> {
  bool _busy = false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _template(ExportFormat format) async {
    try {
      final file = await ref
          .read(importApiProvider)
          .template(widget.kind, format);
      final path = await ref.read(saveExportProvider)(file);
      _snack('Modèle enregistré sur ce poste : $path');
    } on ApiException catch (error) {
      _snack(error.userMessage);
    } on Exception {
      _snack('Le modèle n’a pas pu être enregistré sur ce poste.');
    }
  }

  Future<void> _import() async {
    final picked = await ref.read(pickImportFileProvider)();
    if (picked == null || !mounted) return;
    final api = ref.read(importApiProvider);
    setState(() => _busy = true);
    try {
      final check = await api.send(
        widget.kind,
        picked.bytes,
        picked.name,
        dryRun: true,
      );
      if (!mounted) return;
      // La roue ne tourne que pendant l'envoi, pas derrière le compte rendu.
      setState(() => _busy = false);
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => _ReportDialog(
          kind: widget.kind,
          filename: picked.name,
          report: check,
        ),
      );
      if (go != true || !mounted) return;
      setState(() => _busy = true);
      final done = await api.send(
        widget.kind,
        picked.bytes,
        picked.name,
        dryRun: false,
      );
      widget.onImported?.call();
      _snack('${done.created} ${widget.kind.label} importé(s).');
    } on ApiException catch (error) {
      _snack(error.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return PopupMenuButton<String>(
      tooltip: 'Importer',
      icon: const Icon(Icons.file_upload_outlined),
      onSelected: (choice) => switch (choice) {
        'xlsx' => _template(ExportFormat.xlsx),
        'csv' => _template(ExportFormat.csv),
        _ => _import(),
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'import',
          child: Text('Importer des ${widget.kind.label}…'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'xlsx',
          child: Text('Télécharger le modèle (Excel)'),
        ),
        const PopupMenuItem(
          value: 'csv',
          child: Text('Télécharger le modèle (CSV)'),
        ),
      ],
    );
  }
}

/// Résultat de la vérification à blanc. « Importer » n'est proposé que pour un
/// fichier sans erreur : le serveur refuserait de toute façon, tout ou rien.
class _ReportDialog extends StatelessWidget {
  const _ReportDialog({
    required this.kind,
    required this.filename,
    required this.report,
  });

  final ImportKind kind;
  final String filename;
  final ImportReport report;

  @override
  Widget build(BuildContext context) {
    final errors = report.errors;
    return AlertDialog(
      title: Text(filename),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${report.total} ligne(s) lue(s) — ${report.ready} prête(s), '
              '${errors.length} en erreur.',
            ),
            if (errors.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                'Corrigez ces lignes dans le fichier, puis réessayez : rien '
                'n’est importé tant qu’il reste une erreur.',
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final e in errors.take(50))
                      Text('Ligne ${e.line} : ${e.message}'),
                    if (errors.length > 50)
                      Text('… et ${errors.length - 50} autre(s).'),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(errors.isEmpty ? 'Annuler' : 'Fermer'),
        ),
        if (errors.isEmpty && report.ready > 0)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Importer ${report.ready} ${kind.label}'),
          ),
      ],
    );
  }
}
