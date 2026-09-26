import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/api_exception.dart';
import '../../core/file_export.dart';

/// Ce qu'un écran permet d'exporter : un libellé VISIBLE (sur un écran tactile,
/// une infobulle n'apparaît qu'à l'appui long) et le téléchargement.
class ExportTarget {
  const ExportTarget(this.label, this.fetch);

  final String label;

  /// Télécharge le fichier dans le format choisi (client d'API de la feature).
  final Future<ExportedFile> Function(ExportFormat format) fetch;
}

/// « Exporter » : UN bouton par écran, un menu qui dit quoi et dans quel
/// format. Le serveur rend le fichier et applique la garde de la liste : ce
/// bouton n'ouvre rien de plus.
class ExportButton extends ConsumerStatefulWidget {
  const ExportButton({required this.targets, super.key});

  final List<ExportTarget> targets;

  @override
  ConsumerState<ExportButton> createState() => _ExportButtonState();
}

class _ExportButtonState extends ConsumerState<ExportButton> {
  bool _busy = false;

  Future<void> _export((ExportTarget, ExportFormat) choice) async {
    final (target, format) = choice;
    final messenger = ScaffoldMessenger.of(context);
    final save = ref.read(saveExportProvider);
    setState(() => _busy = true);
    String message;
    try {
      final path = await save(await target.fetch(format));
      // Le fichier RESTE sur ce poste, déconnexion comprise : le dire.
      message = 'Enregistré sur ce poste : $path';
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
    final single = widget.targets.length == 1;
    return PopupMenuButton<(ExportTarget, ExportFormat)>(
      tooltip: 'Exporter',
      icon: const Icon(Icons.file_download_outlined),
      onSelected: _export,
      itemBuilder: (context) => [
        for (final target in widget.targets) ...[
          PopupMenuItem(
            enabled: false,
            height: 32,
            child: Text(
              target.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          for (final format in ExportFormat.values)
            PopupMenuItem(
              value: (target, format),
              child: Text(single ? format.label : '   ${format.label}'),
            ),
        ],
      ],
    );
  }
}
