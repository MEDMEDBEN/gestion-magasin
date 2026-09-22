import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/transfers_controller.dart';
import '../data/transfers_models.dart';

/// Une ligne en cours de saisie : produit choisi + quantité demandée.
class _LineFields {
  _LineFields() : quantity = TextEditingController();

  String? productId;
  final TextEditingController quantity;

  void dispose() => quantity.dispose();
}

/// Demande du magasin au dépôt (spec §16) : le vendeur dit ce qu'il lui manque.
/// Aucun stock ne bouge ici — la marchandise part à l'expédition du dépôt.
class TransferRequestForm extends ConsumerStatefulWidget {
  const TransferRequestForm({super.key});

  @override
  ConsumerState<TransferRequestForm> createState() =>
      _TransferRequestFormState();
}

class _TransferRequestFormState extends ConsumerState<TransferRequestForm> {
  final _formKey = GlobalKey<FormState>();

  /// Intention stable : tous les essais de CETTE demande portent la même clé.
  late final String _intent = 'transfer:${ref.read(uuidProvider).v7()}';
  final List<_LineFields> _lines = [_LineFields()];
  final _comment = TextEditingController();
  TransferPriority _priority = TransferPriority.normal;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final outcome = await ref
          .read(transfersActionsProvider)
          .request(
            intent: _intent,
            priority: _priority,
            comment: _comment.text.trim().isEmpty ? null : _comment.text.trim(),
            lines: [
              for (final l in _lines)
                (
                  productId: l.productId!,
                  quantity: parseQuantity(l.quantity.text)!,
                ),
            ],
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            transferOutcomeText(
              outcome,
              done: (t) => '${t.number} envoyée au dépôt — ${t.status.label}.',
            ),
          ),
        ),
      );
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.userMessage;
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final products =
        ref.watch(activeProductsProvider).value ?? const <Product>[];

    return FormPanelFrame(
      formKey: _formKey,
      title: 'Nouvelle demande au dépôt',
      saving: _saving,
      error: _error,
      submitLabel: 'Envoyer la demande',
      onSubmit: _saving ? null : _submit,
      children: [
        const AmpereInlineAlert(
          tone: StatusTone.info,
          icon: LucideIcons.info,
          message:
              'Le dépôt prépare puis expédie. La marchandise n’est vendable au '
              'magasin qu’une fois réceptionnée ici.',
        ),
        const SizedBox(height: 16),
        const AmpereFieldLabel('Priorité'),
        DropdownButtonFormField<TransferPriority>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: _priority,
          isExpanded: true,
          items: [
            for (final p in TransferPriority.values)
              DropdownMenuItem(value: p, child: Text(p.label)),
          ],
          onChanged: _saving
              ? null
              : (v) => setState(() => _priority = v ?? _priority),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < _lines.length; i++) _lineRow(i, products, colors),
        if (!_saving)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _lines.length >= 200
                  ? null
                  : () => setState(() => _lines.add(_LineFields())),
              icon: const Icon(LucideIcons.plus, size: 16),
              label: const Text('Ajouter une ligne'),
            ),
          ),
        const SizedBox(height: 8),
        const AmpereFieldLabel('Commentaire'),
        TextFormField(
          controller: _comment,
          enabled: !_saving,
          maxLength: 500,
          maxLines: 2,
          decoration: const InputDecoration(
            hintText: 'Rupture en rayon, client qui attend…',
          ),
        ),
      ],
    );
  }

  Widget _lineRow(int index, List<Product> products, AmpereColors colors) {
    final line = _lines[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: AmpereFieldLabel('Ligne ${index + 1}')),
              if (!_saving && _lines.length > 1)
                IconButton(
                  tooltip: 'Retirer la ligne',
                  icon: Icon(LucideIcons.trash2, size: 16, color: colors.error),
                  onPressed: () => setState(() {
                    _lines.removeAt(index).dispose();
                  }),
                ),
            ],
          ),
          DropdownButtonFormField<String>(
            icon: const Icon(LucideIcons.chevronDown, size: 17),
            initialValue: products.any((p) => p.id == line.productId)
                ? line.productId
                : null,
            isExpanded: true,
            hint: const Text('Produit'),
            items: [
              for (final p in products)
                DropdownMenuItem(
                  value: p.id,
                  child: Text('${p.name} · ${p.sku}'),
                ),
            ],
            onChanged: _saving
                ? null
                : (v) => setState(() => line.productId = v),
            validator: (v) {
              if (v == null) return 'Choisissez un produit';
              // Miroir du serveur : un produit ne figure qu'une fois.
              final twice = _lines.where((l) => l.productId == v).length > 1;
              return twice ? 'Ce produit est déjà demandé' : null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: line.quantity,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Quantité demandée'),
            validator: (v) {
              final q = parseQuantity(v ?? '');
              if (q == null || q <= Quantity.zero) return 'Quantité > 0';
              if (q.scale > quantityScale) return '3 décimales au maximum';
              return null;
            },
          ),
        ],
      ),
    );
  }
}
