import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../suppliers/application/suppliers_controller.dart';
import '../application/purchases_controller.dart';
import '../data/purchases_models.dart';

/// Ligne en cours de saisie : champs texte + produit choisi.
class _LineFields {
  _LineFields({this.productId, String quantity = '', String price = ''})
    : quantity = TextEditingController(text: quantity),
      price = TextEditingController(text: price);

  String? productId;
  final TextEditingController quantity;
  final TextEditingController price;

  void dispose() {
    quantity.dispose();
    price.dispose();
  }
}

/// Création ou modification d'une commande fournisseur. `readOnly` : une
/// commande confirmée se consulte (lignes, reçu, reste) sans se modifier.
class PurchaseOrderForm extends ConsumerStatefulWidget {
  const PurchaseOrderForm({super.key, this.existing, this.readOnly = false});

  final PurchaseOrder? existing;
  final bool readOnly;

  @override
  ConsumerState<PurchaseOrderForm> createState() => _PurchaseOrderFormState();
}

class _PurchaseOrderFormState extends ConsumerState<PurchaseOrderForm> {
  final _formKey = GlobalKey<FormState>();
  late final String _id = widget.existing?.id ?? ref.read(uuidProvider).v7();
  late String? _supplierId = widget.existing?.supplierId;
  late final List<_LineFields> _lines = widget.existing == null
      ? [_LineFields()]
      : [
          for (final l in widget.existing!.lines)
            _LineFields(
              productId: l.productId,
              quantity: formatQuantity(l.orderedQuantity),
              price: formatDA(l.unitPriceHt, withSymbol: false),
            ),
        ];
  bool _saving = false;
  String? _error;

  bool get _locked => widget.readOnly || _saving;

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  /// Total HT estimé (le serveur recalcule et fait foi).
  int get _estimateHt {
    var total = 0;
    for (final l in _lines) {
      final q = parseQuantity(l.quantity.text);
      final p = parseDA(l.price.text);
      if (q == null || p == null) continue;
      total += (q * Quantity.fromInt(p)).round().toBigInt().toInt();
    }
    return total;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final order = await ref
          .read(purchasesActionsProvider)
          .save(
            id: _id,
            isNew: widget.existing == null,
            supplierId: _supplierId!,
            lines: [
              for (final l in _lines)
                (
                  productId: l.productId!,
                  quantity: parseQuantity(l.quantity.text)!,
                  unitPriceHt: parseDA(l.price.text)!,
                ),
            ],
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${order.number} enregistrée — ${formatDA(order.totalTtc)} TTC.',
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
    final suppliers = ref.watch(supplierSearchProvider('')).value ?? const [];
    final products =
        ref.watch(activeProductsProvider).value ?? const <Product>[];
    final existing = widget.existing;

    return FormPanelFrame(
      formKey: _formKey,
      title: existing == null ? 'Nouvelle commande' : existing.number,
      saving: _saving,
      error: _error,
      submitLabel: 'Enregistrer la commande',
      onSubmit: _locked ? null : _submit,
      children: [
        const AmpereFieldLabel('Fournisseur'),
        DropdownButtonFormField<String>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: suppliers.any((s) => s.id == _supplierId)
              ? _supplierId
              : null,
          isExpanded: true,
          hint: const Text('Choisir un fournisseur'),
          items: [
            for (final s in suppliers)
              DropdownMenuItem(value: s.id, child: Text(s.name)),
          ],
          // Le fournisseur d'une commande existante ne change pas.
          onChanged: _locked || existing != null
              ? null
              : (v) => setState(() => _supplierId = v),
          validator: (v) => v == null ? 'Choisissez un fournisseur' : null,
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < _lines.length; i++) _lineRow(i, products, colors),
        if (!_locked)
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
        const Divider(height: 24),
        Text(
          'Total HT estimé : ${formatDA(_estimateHt)}'
          '${existing == null ? '' : ' · enregistré ${formatDA(existing.totalTtc)} TTC'}',
          style: AmpereType.bodyStrong.copyWith(color: colors.ink),
        ),
        Text(
          'La TVA du produit est figée à l’enregistrement. La dette fournisseur '
          'ne bouge qu’à la réception.',
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
      ],
    );
  }

  Widget _lineRow(int index, List<Product> products, AmpereColors colors) {
    final line = _lines[index];
    final received =
        widget.existing != null && index < widget.existing!.lines.length
        ? widget.existing!.lines[index]
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: AmpereFieldLabel('Ligne ${index + 1}')),
              if (!_locked && _lines.length > 1)
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
            onChanged: _locked
                ? null
                : (v) => setState(() => line.productId = v),
            validator: (v) => v == null ? 'Choisissez un produit' : null,
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  controller: line.quantity,
                  enabled: !_locked,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Quantité'),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    final q = parseQuantity(v ?? '');
                    return q == null || q <= Quantity.zero
                        ? 'Quantité > 0'
                        : null;
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: line.price,
                  enabled: !_locked,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Prix d’achat HT',
                    suffixText: 'DA',
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    final p = parseDA(v ?? '');
                    return p == null || p < 0 ? 'Prix invalide' : null;
                  },
                ),
              ),
            ],
          ),
          if (received != null && widget.readOnly)
            Text(
              'Reçu ${formatQuantity(received.receivedQuantity)} · reste '
              '${formatQuantity(received.remainingQuantity)}',
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
        ],
      ),
    );
  }
}
