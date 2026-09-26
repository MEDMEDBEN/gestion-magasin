import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/api_exception.dart';
import '../../core/file_export.dart';

/// « Exporter » : Excel, CSV ou PDF, enregistré sur le poste. Le serveur rend
/// le fichier et applique la garde de l'écran : ce bouton n'ouvre rien de plus.
class ExportButton extends ConsumerStatefulWidget {
  const ExportButton({required this.fetch, super.key});

  /// Télécharge le fichier dans le format choisi (client d'API de la feature).
  final Future<ExportedFile> Function(ExportFormat format) fetch;

  @override
  ConsumerState<ExportButton> createState() => _ExportButtonState();
}

class _ExportButtonState extends ConsumerState<ExportButton> {
  bool _busy = false;

  Future<void> _export(ExportFormat format) async {
    final messenger = ScaffoldMessenger.of(context);
    final save = ref.read(saveExportProvider);
    setState(() => _busy = true);
    String message;
    try {
      final path = await save(await widget.fetch(format));
      message = 'Enregistré : $path';
    } on ApiException catch (error) {
      message = error.userMessage;
    } on Exception {
      message = 'Le fichier n’a pas pu être enregistré sur ce poste.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
    return PopupMenuButton<ExportFormat>(
      tooltip: 'Exporter',
      icon: const Icon(Icons.file_download_outlined),
      onSelected: _export,
      itemBuilder: (context) => [
        for (final format in ExportFormat.values)
          PopupMenuItem(value: format, child: Text(format.label)),
      ],
    );
  }
}
