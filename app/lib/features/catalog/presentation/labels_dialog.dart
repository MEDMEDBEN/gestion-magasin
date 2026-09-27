import 'package:flutter/material.dart';

/// Choix d'impression des étiquettes (spec §8ter) : le support et le nombre
/// d'exemplaires par produit. Rend `null` si l'utilisateur annule.
Future<({String format, int copies})?> askLabels(
  BuildContext context, {
  required int productCount,
}) {
  return showDialog<({String format, int copies})>(
    context: context,
    builder: (context) => _LabelsDialog(productCount: productCount),
  );
}

class _LabelsDialog extends StatefulWidget {
  const _LabelsDialog({required this.productCount});

  final int productCount;

  @override
  State<_LabelsDialog> createState() => _LabelsDialogState();
}

class _LabelsDialogState extends State<_LabelsDialog> {
  String _format = 'A4';
  final _copies = TextEditingController(text: '1');
  String? _error;

  @override
  void dispose() {
    _copies.dispose();
    super.dispose();
  }

  void _confirm() {
    final copies = int.tryParse(_copies.text.trim());
    // Mêmes bornes que le serveur : 1 à 100 par produit, 1 000 au total.
    if (copies == null || copies < 1 || copies > 100) {
      setState(() => _error = 'Entre 1 et 100 par produit');
      return;
    }
    if (copies * widget.productCount > 1000) {
      setState(() => _error = '1 000 étiquettes au plus par impression');
      return;
    }
    Navigator.of(context).pop((format: _format, copies: copies));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Étiquettes — ${widget.productCount} produit(s)'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'A4', label: Text('Planche A4')),
              ButtonSegment(value: 'ROULEAU', label: Text('Rouleau')),
            ],
            selected: {_format},
            onSelectionChanged: (s) => setState(() => _format = s.first),
          ),
          const SizedBox(height: 6),
          Text(
            _format == 'A4'
                ? '24 étiquettes 70 × 37 mm par feuille'
                : 'Imprimante thermique, étiquettes 50 × 30 mm',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _copies,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Exemplaires par produit',
              errorText: _error,
            ),
            onSubmitted: (_) => _confirm(),
          ),
          const SizedBox(height: 8),
          const Text(
            'Prix du tarif par défaut, TTC — celui encaissé en caisse.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _confirm, child: const Text('Imprimer')),
      ],
    );
  }
}
