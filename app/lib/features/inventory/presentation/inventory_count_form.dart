import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/inventory_controller.dart';
import '../data/inventory_models.dart';

class _LineFields {
  _LineFields(this.line)
    : counted = TextEditingController(
        text: line.countedQuantity == null
            ? ''
            : formatQuantity(line.countedQuantity!),
      );

  final InventoryLine line;
  final TextEditingController counted;

  void dispose() => counted.dispose();
}

/// Saisie du comptage physique (spec §22). Le théorique n'est PAS pré-rempli :
/// afficher la réponse attendue est le meilleur moyen d'obtenir un comptage
/// complaisant. Il est montré à côté, une fois la saisie faite.
class InventoryCountForm extends ConsumerStatefulWidget {
  const InventoryCountForm({super.key, required this.inventory});

  final Inventory inventory;

  @override
  ConsumerState<InventoryCountForm> createState() => _InventoryCountFormState();
}

class _InventoryCountFormState extends ConsumerState<InventoryCountForm> {
  final _formKey = GlobalKey<FormState>();
  late final List<_LineFields> _lines = [
    for (final l in widget.inventory.lines) _LineFields(l),
  ];
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _submit({bool done = false}) async {
    if (!_formKey.currentState!.validate()) return;
    final counted = <String, Quantity>{
      for (final l in _lines)
        if (l.counted.text.trim().isNotEmpty)
          l.line.productId: parseQuantity(l.counted.text)!,
    };
    if (counted.isEmpty) {
      setState(() => _error = 'Saisissez au moins une quantité comptée.');
      return;
    }
    if (done && counted.length < _lines.length) {
      setState(
        () => _error =
            'Comptage incomplet : ${_lines.length - counted.length} produit(s) '
            'sans quantité. Enregistrez-le « en cours », ou complétez-le.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await ref
          .read(inventoryActionsProvider)
          .count(widget.inventory.id, counted, done: done);
      if (!mounted) return;
      Navigator.of(context).pop();
      final gaps = updated.gaps.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${updated.number} : ${updated.status.label}'
            '${gaps == 0 ? ' — aucun écart.' : ' — $gaps écart(s) à faire valider.'}',
          ),
        ),
      );
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          // Le comptage reste EN LIGNE (docs/context.md §9) : le serveur seul
          // sait à quoi comparer les quantités. On le DIT, au lieu de laisser
          // croire à une panne passagère.
          _error = error.isOffline
              ? 'Comptage impossible hors ligne : il se compare au stock du '
                    'serveur. Reconnectez-vous pour l’enregistrer.'
              : error.userMessage;
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final products = {
      for (final p
          in ref.watch(activeProductsProvider).value ?? const <Product>[])
        p.id: p,
    };

    return FormPanelFrame(
      formKey: _formKey,
      title: 'Compter ${widget.inventory.number}',
      saving: _saving,
      error: _error,
      submitLabel: 'Terminer le comptage',
      onSubmit: _saving ? null : () => _submit(done: true),
      children: [
        const AmpereInlineAlert(
          tone: StatusTone.info,
          icon: LucideIcons.info,
          message:
              'Comptez ce que vous avez sous les yeux. L’écart apparaîtra '
              'ensuite ; le stock ne bouge qu’à la validation de l’administrateur.',
        ),
        const SizedBox(height: 16),
        for (final fields in _lines) _lineRow(fields, products, colors),
        const Divider(height: 24),
        Text(
          'Comptage en plusieurs passages : enregistrez-le « en cours », il vous '
          'attendra. Il ne se valide qu’une fois terminé.',
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _saving ? null : () => _submit(),
            icon: const Icon(LucideIcons.save, size: 16),
            label: const Text('Enregistrer en cours'),
          ),
        ),
      ],
    );
  }

  Widget _lineRow(
    _LineFields fields,
    Map<String, Product> products,
    AmpereColors colors,
  ) {
    final line = fields.line;
    final product = products[line.productId];
    final alreadyCounted = line.countedQuantity != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AmpereFieldLabel(product?.name ?? 'Produit'),
          TextFormField(
            controller: fields.counted,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Quantité comptée',
              hintText: 'Laisser vide pour compter plus tard',
              // Le théorique n'est révélé qu'APRÈS un premier comptage : le
              // compteur ne doit pas se contenter de recopier l'attendu.
              helperText: alreadyCounted
                  ? 'Théorique ${formatQuantity(line.theoreticalQuantity)} · '
                        'écart ${formatQuantity(line.difference)}'
                  : null,
            ),
            onChanged: (_) => setState(() {}),
            validator: (v) {
              final text = (v ?? '').trim();
              if (text.isEmpty) return null;
              final q = parseQuantity(text);
              if (q == null || q < Quantity.zero) return 'Quantité invalide';
              if (q.scale > quantityScale) return '3 décimales au maximum';
              return null;
            },
          ),
        ],
      ),
    );
  }
}
