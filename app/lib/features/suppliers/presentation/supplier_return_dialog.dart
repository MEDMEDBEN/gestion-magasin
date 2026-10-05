import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/quantity.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/suppliers_controller.dart';
import '../data/suppliers_models.dart';
import '../../../ui/widgets/search_picker.dart';

/// Retour de marchandise à un fournisseur (P1 bis n°21l) : produit, quantité,
/// lieu d'où elle part, motif. Le serveur borne la quantité au reçu non encore
/// renvoyé, prend le prix de la dernière réception et réduit la dette. Rend
/// le retour enregistré (`number`, `id`, `totalTtc`), ou `null`.
Future<Map<String, dynamic>?> showSupplierReturnDialog(
  BuildContext context,
  Supplier supplier,
) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (context) => _SupplierReturnDialog(supplier: supplier),
);

class _SupplierReturnDialog extends ConsumerStatefulWidget {
  const _SupplierReturnDialog({required this.supplier});

  final Supplier supplier;

  @override
  ConsumerState<_SupplierReturnDialog> createState() =>
      _SupplierReturnDialogState();
}

class _SupplierReturnDialogState extends ConsumerState<_SupplierReturnDialog> {
  final _quantity = TextEditingController();
  final _reason = TextEditingController();
  String? _productId;
  String? _locationId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _quantity.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final quantity = parseQuantity(_quantity.text.trim());
    if (_productId == null || _locationId == null) {
      setState(() => _error = 'Choisissez le produit et le lieu');
      return;
    }
    if (quantity == null || quantity <= Quantity.zero) {
      setState(() => _error = 'Quantité invalide');
      return;
    }
    if (_reason.text.trim().length < 2) {
      setState(() => _error = 'Motif obligatoire');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final done = await ref
          .read(suppliersActionsProvider)
          .returnGoods(
            widget.supplier.id,
            productId: _productId!,
            quantity: quantity,
            locationId: _locationId!,
            reason: _reason.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(done);
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
    final products = ref.watch(activeProductsProvider).value ?? const [];
    final locations = (ref.watch(locationsProvider).value ?? const [])
        .where((l) => l.isActive && (l.type == 'DEPOT' || l.type == 'MAGASIN'))
        .toList();
    _locationId ??= locations.where((l) => l.type == 'DEPOT').firstOrNull?.id;
    return AlertDialog(
      title: Text('Retour à ${widget.supplier.name}'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SearchPickerField<Product>(
              options: products,
              idOf: (p) => p.id,
              labelOf: (p) => '${p.sku} — ${p.name}',
              searchTextOf: (p) => '${p.name} ${p.sku} ${p.barcode}',
              value: _productId,
              hint: 'Produit',
              onChanged: _saving ? null : (v) => setState(() => _productId = v),
            ),
            TextField(
              controller: _quantity,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Quantité renvoyée'),
            ),
            DropdownButtonFormField<String>(
              initialValue: _locationId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Part de'),
              items: [
                for (final l in locations)
                  DropdownMenuItem(value: l.id, child: Text(l.name)),
              ],
              onChanged: _saving
                  ? null
                  : (v) => setState(() => _locationId = v),
            ),
            TextField(
              controller: _reason,
              enabled: !_saving,
              maxLength: 300,
              decoration: const InputDecoration(labelText: 'Motif'),
            ),
            const Text(
              'Prix de la dernière réception chez ce fournisseur ; la dette '
              'baisse du montant renvoyé.',
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: const Text('Enregistrer le retour'),
        ),
      ],
    );
  }
}
