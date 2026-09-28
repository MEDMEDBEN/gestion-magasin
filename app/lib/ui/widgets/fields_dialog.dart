import 'package:flutter/material.dart';

/// Petit formulaire en dialogue (un ou plusieurs champs texte). Rend les
/// valeurs saisies (rognées), ou `null` si annulé. Le dialogue POSSÈDE ses
/// contrôleurs : ils vivent jusqu'à la fin de son animation de fermeture.
Future<Map<String, String>?> askFields(
  BuildContext context, {
  required String title,
  required List<({String key, String label, String initial})> fields,
  String confirm = 'Enregistrer',
}) => showDialog<Map<String, String>>(
  context: context,
  builder: (context) =>
      _FieldsDialog(title: title, fields: fields, confirm: confirm),
);

class _FieldsDialog extends StatefulWidget {
  const _FieldsDialog({
    required this.title,
    required this.fields,
    required this.confirm,
  });

  final String title;
  final List<({String key, String label, String initial})> fields;
  final String confirm;

  @override
  State<_FieldsDialog> createState() => _FieldsDialogState();
}

class _FieldsDialogState extends State<_FieldsDialog> {
  late final _controllers = {
    for (final f in widget.fields)
      f.key: TextEditingController(text: f.initial),
  };

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, f) in widget.fields.indexed)
          TextField(
            controller: _controllers[f.key],
            autofocus: i == 0,
            decoration: InputDecoration(labelText: f.label),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Annuler'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop({
          for (final e in _controllers.entries) e.key: e.value.text.trim(),
        }),
        child: Text(widget.confirm),
      ),
    ],
  );
}
