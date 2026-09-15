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
import '../../catalog/data/catalog_repository.dart';
import '../application/stock_controller.dart';
import '../data/stock_models.dart';

/// Déclaration d'une perte / casse. `appliesImmediately` : l'ADMIN applique
/// tout de suite ; sinon (MAGASINIER) la déclaration attend sa validation —
/// c'est le serveur qui en décide, l'écran ne fait que l'annoncer.
class LossForm extends ConsumerStatefulWidget {
  const LossForm({super.key, required this.appliesImmediately});

  final bool appliesImmediately;

  @override
  ConsumerState<LossForm> createState() => _LossFormState();
}

class _LossFormState extends ConsumerState<LossForm> {
  final _formKey = GlobalKey<FormState>();
  final _quantity = TextEditingController();
  final _comment = TextEditingController();
  Product? _product;
  String? _locationId;
  String? _productError;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _quantity.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final valid = _formKey.currentState!.validate();
    setState(
      () => _productError = _product == null ? 'Choisissez un produit' : null,
    );
    if (!valid || _product == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final comment = _comment.text.trim();
      final loss = await ref
          .read(stockActionsProvider)
          .declareLoss(
            productId: _product!.id,
            locationId: _locationId!,
            quantity: parseQuantity(_quantity.text)!,
            comment: comment.isEmpty ? null : comment,
          );
      if (mounted) Navigator.of(context).pop<StockLoss>(loss);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.userMessage;
      });
    }
  }

  String? _validateQuantity(String? value) {
    final quantity = parseQuantity(value ?? '');
    if (quantity == null || quantity <= Quantity.zero) {
      return 'Quantité positive, ex. 2 ou 12,5';
    }
    if (quantity.scale > quantityScale) return '3 décimales au maximum';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final products = [
      for (final p
          in ref.watch(activeProductsProvider).value ?? const <Product>[])
        p,
    ];
    // Le stock vit au magasin ou au dépôt ; les positions (EMPLACEMENT) ne
    // portent pas de stock.
    final stockLocations = [
      for (final l in ref.watch(locationsProvider).value ?? const [])
        if (l.isActive && (l.type == 'MAGASIN' || l.type == 'DEPOT')) l,
    ];
    final inputStyle = AmpereType.input.copyWith(color: colors.ink);

    return FormPanelFrame(
      formKey: _formKey,
      title: 'Déclarer une perte',
      submitLabel: widget.appliesImmediately
          ? 'Déclarer et retirer du stock'
          : 'Envoyer pour validation',
      onSubmit: _submit,
      saving: _saving,
      error: _error,
      children: [
        AmpereInlineAlert(
          tone: StatusTone.info,
          icon: LucideIcons.info,
          message: widget.appliesImmediately
              ? 'La quantité est retirée du stock dès l’enregistrement.'
              : 'L’administrateur valide la déclaration avant que le stock '
                    'ne soit modifié.',
        ),
        const SizedBox(height: 16),
        const AmpereFieldLabel('Produit'),
        Autocomplete<Product>(
          displayStringForOption: (p) => '${p.name} — ${p.sku}',
          optionsBuilder: (value) {
            final term = foldForSearch(value.text);
            if (term.isEmpty) return const Iterable<Product>.empty();
            return products
                .where(
                  (p) => foldForSearch(
                    '${p.name} ${p.sku} ${p.barcode}',
                  ).contains(term),
                )
                .take(20);
          },
          onSelected: (p) => setState(() {
            _product = p;
            _productError = null;
          }),
          fieldViewBuilder: (context, controller, focusNode, onSubmit) =>
              TextField(
                controller: controller,
                focusNode: focusNode,
                enabled: !_saving,
                autocorrect: false,
                style: inputStyle,
                decoration: InputDecoration(
                  prefixIcon: const Icon(LucideIcons.search, size: 17),
                  hintText: 'Nom, référence ou code-barres',
                  errorText: _productError,
                ),
                onChanged: (_) {
                  if (_product != null) setState(() => _product = null);
                },
              ),
        ),
        formFieldGap,
        const AmpereFieldLabel('Où'),
        DropdownButtonFormField<String>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: _locationId,
          hint: const Text('Magasin ou dépôt'),
          decoration: const InputDecoration(
            prefixIcon: Icon(LucideIcons.warehouse, size: 17),
          ),
          items: [
            for (final l in stockLocations)
              DropdownMenuItem(value: l.id, child: Text(l.name)),
          ],
          validator: (v) =>
              v == null ? 'Choisissez le magasin ou le dépôt' : null,
          onChanged: _saving ? null : (v) => setState(() => _locationId = v),
        ),
        formFieldGap,
        const AmpereFieldLabel('Quantité perdue'),
        TextFormField(
          controller: _quantity,
          enabled: !_saving,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: inputStyle,
          decoration: InputDecoration(suffixText: _product?.unit.short),
          validator: _validateQuantity,
        ),
        formFieldGap,
        const AmpereFieldLabel('Constat'),
        TextFormField(
          controller: _comment,
          enabled: !_saving,
          maxLength: 500,
          minLines: 2,
          maxLines: 4,
          style: inputStyle,
          decoration: const InputDecoration(
            hintText: 'Ex. carton écrasé à la réception',
          ),
        ),
      ],
    );
  }
}
