import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
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
///
/// `LossForm.entry` : le même formulaire pour AJOUTER du stock sans achat
/// (décision du 2026-10-13) — motif obligatoire, auteur tracé ; rend le
/// mouvement créé.
class LossForm extends ConsumerStatefulWidget {
  const LossForm({super.key, required this.appliesImmediately, this.product})
    : entry = false;

  const LossForm.entry({super.key, this.product})
    : appliesImmediately = true,
      entry = true;

  final bool appliesImmediately;

  /// Entrée de stock (ajout) au lieu d'une perte (retrait).
  final bool entry;

  /// Produit déjà choisi (depuis sa fiche de stock).
  final Product? product;

  @override
  ConsumerState<LossForm> createState() => _LossFormState();
}

class _LossFormState extends ConsumerState<LossForm> {
  final _formKey = GlobalKey<FormState>();
  final _quantity = TextEditingController();
  final _comment = TextEditingController();
  late final String _declarationId = ref.read(uuidProvider).v7();
  late Product? _product = widget.product;
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
      if (widget.entry) {
        final movement = await ref
            .read(stockActionsProvider)
            .addEntry(
              id: _declarationId,
              productId: _product!.id,
              locationId: _locationId!,
              quantity: parseQuantity(_quantity.text)!,
              comment: comment,
            );
        if (mounted) Navigator.of(context).pop<StockMovementEntry>(movement);
        return;
      }
      final loss = await ref
          .read(stockActionsProvider)
          .declareLoss(
            id: _declarationId,
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
      title: widget.entry ? 'Ajouter du stock' : 'Déclarer une perte',
      submitLabel: widget.entry
          ? 'Ajouter au stock'
          : widget.appliesImmediately
          ? 'Déclarer et retirer du stock'
          : 'Envoyer pour validation',
      onSubmit: _submit,
      saving: _saving,
      error: _error,
      children: [
        AmpereInlineAlert(
          tone: widget.entry ? StatusTone.ok : StatusTone.info,
          icon: LucideIcons.info,
          message: widget.entry
              ? 'Pour du stock déjà là (sans achat) : la quantité est ajoutée '
                    'tout de suite, à votre nom, avec le motif. Une livraison '
                    'fournisseur passe plutôt par Achats (coût d’achat).'
              : widget.appliesImmediately
              ? 'La quantité est retirée du stock dès l’enregistrement.'
              : 'L’administrateur valide la déclaration avant que le stock '
                    'ne soit modifié.',
        ),
        const SizedBox(height: 16),
        const AmpereFieldLabel('Produit'),
        Autocomplete<Product>(
          initialValue: widget.product == null
              ? null
              : TextEditingValue(
                  text: '${widget.product!.name} — ${widget.product!.sku}',
                ),
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
        AmpereFieldLabel(widget.entry ? 'Quantité ajoutée' : 'Quantité perdue'),
        TextFormField(
          controller: _quantity,
          enabled: !_saving,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: inputStyle,
          decoration: InputDecoration(suffixText: _product?.unit.short),
          validator: _validateQuantity,
        ),
        formFieldGap,
        AmpereFieldLabel(widget.entry ? 'Motif (obligatoire)' : 'Constat'),
        TextFormField(
          controller: _comment,
          enabled: !_saving,
          maxLength: 500,
          minLines: 2,
          maxLines: 4,
          style: inputStyle,
          decoration: InputDecoration(
            hintText: widget.entry
                ? 'Ex. stock déjà en rayon, retrouvé au dépôt'
                : 'Ex. carton écrasé à la réception',
          ),
          validator: widget.entry
              ? (v) => (v ?? '').trim().length < 3
                    ? 'Dites pourquoi ce stock entre'
                    : null
              : null,
        ),
      ],
    );
  }
}
