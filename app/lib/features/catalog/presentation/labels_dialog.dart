import 'package:flutter/material.dart';

/// Impression des étiquettes (spec §8ter) : le nombre d'exemplaires par
/// produit, rien d'autre — le support est FIXE, 35 × 45 mm portrait (décision
/// MEDMEDBEN du 2026-11-13). Rend `null` si l'utilisateur annule.
Future<int?> askLabels(BuildContext context, {required int productCount}) {
  return showDialog<int>(
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
    Navigator.of(context).pop(copies);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Étiquettes — ${widget.productCount} produit(s)'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Imprimante d’étiquettes · 35 × 45 mm, portrait'),
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
          const Text('Prix unitaire TTC du tarif par défaut.'),
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
