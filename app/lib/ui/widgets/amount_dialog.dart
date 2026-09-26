import 'package:flutter/material.dart';

import '../../core/money.dart';

/// Saisie d'un montant en DA (virgule acceptée), renvoyé en centimes.
Future<int?> askAmount(
  BuildContext context, {
  required String title,
  required String label,
  required String confirm,
  String? help,
  int? initial,
}) {
  final controller = TextEditingController(
    text: initial == null ? '' : formatDA(initial, withSymbol: false),
  );
  return showDialog<int>(
    context: context,
    builder: (context) {
      String? error;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              suffixText: 'DA',
              helperText: help,
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                final value = parseDA(controller.text);
                if (value == null || value < 0) {
                  setState(
                    () => error = 'Montant invalide, ex. 5000 ou 1450,50',
                  );
                  return;
                }
                Navigator.of(context).pop(value);
              },
              child: Text(confirm),
            ),
          ],
        ),
      );
    },
  );
}
