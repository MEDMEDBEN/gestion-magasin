import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/catalog_controller.dart';
import '../../stock/application/stock_controller.dart';
import '../../stock/presentation/stock_status.dart';
import '../data/catalog_models.dart';
import 'product_photo.dart';

/// Création, modification ou consultation d'un produit.
///
/// `canEdit` : ADMIN + `product.write` (miroir du guard serveur) ; sinon la
/// fiche est en lecture seule. `canDisable` : `product.disable` en plus.
class ProductForm extends ConsumerStatefulWidget {
  const ProductForm({
    super.key,
    this.existing,
    required this.canEdit,
    required this.canDisable,
    this.canReadStock = false,
    this.canSetPrices = false,
  });

  final Product? existing;
  final bool canEdit;
  final bool canDisable;
  final bool canReadStock;

  /// ADMIN + `price.manage` : les prix sont modifiables ; sinon lecture seule.
  final bool canSetPrices;

  @override
  ConsumerState<ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends ConsumerState<ProductForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _sku;
  late final TextEditingController _name;
  late final TextEditingController _barcode;
  late final TextEditingController _brand;
  late final TextEditingController _description;
  late final TextEditingController _minThreshold;
  late final TextEditingController _safetyStock;

  /// Un champ de prix par tarif, créé à l'arrivée de la liste des tarifs.
  final Map<String, TextEditingController> _prices = {};

  /// Stock présent à la saisie (création seulement) : devient un mouvement
  /// « stock initial » côté serveur, jamais une quantité écrite directement.
  final _storeStock = TextEditingController();
  final _depotStock = TextEditingController();
  late ProductUnit _unit;
  String? _categoryId;
  String? _taxRateId;
  String? _storageLocationId;
  late bool _allowBackorder;
  late bool _isActive;

  /// Nouvelle photo choisie (déjà compressée), ou demande de retrait.
  Uint8List? _newPhoto;
  bool _removePhoto = false;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;
  bool get _locked => !widget.canEdit || _saving;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    _sku = TextEditingController(text: p?.sku ?? '');
    _name = TextEditingController(text: p?.name ?? '');
    _barcode = TextEditingController(text: p?.barcode ?? '');
    _brand = TextEditingController(text: p?.brand ?? '');
    _description = TextEditingController(text: p?.description ?? '');
    _minThreshold = TextEditingController(
      text: p == null ? '' : formatQuantity(p.minThreshold),
    );
    _safetyStock = TextEditingController(
      text: p == null ? '' : formatQuantity(p.safetyStock),
    );
    _unit = p?.unit ?? ProductUnit.piece;
    _categoryId = p?.categoryId;
    _taxRateId = p?.taxRateId;
    _storageLocationId = p?.storageLocationId;
    _allowBackorder = p?.allowBackorder ?? false;
    _isActive = p?.isActive ?? true;
  }

  @override
  void dispose() {
    for (final c in [
      _sku,
      _name,
      _barcode,
      _brand,
      _description,
      _minThreshold,
      _safetyStock,
      _storeStock,
      _depotStock,
      ..._prices.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  static String? _text(TextEditingController c) {
    final value = c.text.trim();
    return value.isEmpty ? null : value;
  }

  static String _quantity(TextEditingController c) =>
      quantityToJson(parseQuantity(c.text) ?? Quantity.zero);

  /// Champs envoyables, au format du serveur.
  Map<String, Object?> _values() => {
    'sku': _sku.text.trim(),
    'name': _name.text.trim(),
    'barcode': _text(_barcode),
    'brand': _text(_brand),
    'description': _text(_description),
    'unit': _unit.code,
    'categoryId': _categoryId,
    'taxRateId': _taxRateId,
    'storageLocationId': _storageLocationId,
    'minThreshold': _quantity(_minThreshold),
    'safetyStock': _quantity(_safetyStock),
    'allowBackorder': _allowBackorder,
    if (_isEdit && widget.canDisable) 'isActive': _isActive,
  };

  static Map<String, Object?> _valuesOf(Product p) => {
    'sku': p.sku,
    'name': p.name,
    'barcode': p.barcode,
    'brand': p.brand,
    'description': p.description,
    'unit': p.unit.code,
    'categoryId': p.categoryId,
    'taxRateId': p.taxRateId,
    'storageLocationId': p.storageLocationId,
    'minThreshold': quantityToJson(p.minThreshold),
    'safetyStock': quantityToJson(p.safetyStock),
    'allowBackorder': p.allowBackorder,
    'isActive': p.isActive,
  };

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final existing = widget.existing;
    final values = _values();
    final Map<String, Object?> payload;
    if (existing == null) {
      // Création : un champ vide n'est pas envoyé — sans code-barres, le
      // serveur en génère un unique (règle 15).
      final locations = _stockLocationIds();
      final initialStock = [
        for (final (type, controller) in [
          ('MAGASIN', _storeStock),
          ('DEPOT', _depotStock),
        ])
          if (locations[type] != null &&
              (parseQuantity(controller.text) ?? Quantity.zero) > Quantity.zero)
            {'locationId': locations[type], 'quantity': _quantity(controller)},
      ];
      payload = {
        for (final e in values.entries)
          if (e.value != null) e.key: e.value,
        if (initialStock.isNotEmpty) 'initialStock': initialStock,
      };
    } else {
      // Un code-barres ne se retire pas : vidé, il reste inchangé.
      if (values['barcode'] == null) values['barcode'] = existing.barcode;
      payload = changedFields(_valuesOf(existing), values);
      if (payload.isEmpty &&
          _newPhoto == null &&
          !_removePhoto &&
          _changedPrices().isEmpty) {
        Navigator.of(context).pop(existing);
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref
          .read(catalogActionsProvider)
          .saveProduct(
            existing?.id,
            payload,
            photo: _newPhoto,
            removePhoto: _removePhoto,
            prices: _changedPrices(),
          );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (error) {
      _fail(error.userMessage);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = message;
    });
  }

  Map<String, String> _stockLocationIds() => {
    for (final l
        in ref.read(locationsProvider).value ?? const <StorageLocation>[])
      if (l.type == 'MAGASIN' || l.type == 'DEPOT') l.type: l.id,
  };

  Widget _quantityField(
    String label,
    TextEditingController controller,
  ) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AmpereFieldLabel(label),
        TextFormField(
          controller: controller,
          enabled: !_locked,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: AmpereType.input.copyWith(color: AmpereColors.of(context).ink),
          decoration: InputDecoration(suffixText: _unit.short),
          validator: _validateQuantity,
        ),
      ],
    ),
  );

  /// Prix saisis qui diffèrent de ceux du produit, en centimes.
  Map<String, int> _changedPrices() {
    final current = {
      for (final p in widget.existing?.prices ?? const <ProductPriceLine>[])
        p.priceTierId: p.priceHt,
    };
    return {
      for (final entry in _prices.entries)
        if (parseDA(entry.value.text) case final int price
            when price != current[entry.key])
          entry.key: price,
    };
  }

  Widget _pricesSection(AmpereColors colors, List<PriceTier> tiers) {
    final existing = {
      for (final p in widget.existing?.prices ?? const <ProductPriceLine>[])
        p.priceTierId: p.priceHt,
    };
    if (!widget.canSetPrices) {
      return Wrap(
        spacing: 16,
        runSpacing: 6,
        children: [
          for (final tier in tiers)
            Text(
              '${tier.name} : ${existing[tier.id] == null ? 'non fixé' : formatDA(existing[tier.id]!)}',
              style: AmpereType.body.copyWith(color: colors.ink),
            ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, tier) in tiers.indexed) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AmpereFieldLabel('Prix ${tier.name} (HT)'),
                TextFormField(
                  controller: _prices.putIfAbsent(
                    tier.id,
                    () => TextEditingController(
                      text: existing[tier.id] == null
                          ? ''
                          : formatDA(existing[tier.id]!, withSymbol: false),
                    ),
                  ),
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: AmpereType.input.copyWith(color: colors.ink),
                  decoration: const InputDecoration(suffixText: 'DA'),
                  validator: (v) {
                    final raw = v?.trim() ?? '';
                    if (raw.isEmpty) return null;
                    final price = parseDA(raw);
                    return price == null || price < 0
                        ? 'Montant invalide, ex. 1450,50'
                        : null;
                  },
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickPhoto() async {
    final photo = await ref.read(pickProductPhotoProvider)();
    if (!mounted) return;
    if (photo == null) return;
    setState(() {
      _newPhoto = photo;
      _removePhoto = false;
    });
  }

  Widget _photoSection(AmpereColors colors) {
    final existing = widget.existing;
    final hasPhoto =
        _newPhoto != null || (!_removePhoto && existing?.imageKey != null);
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AmpereGeometry.iconChipRadius),
          child: SizedBox(
            width: 96,
            height: 96,
            child: _newPhoto != null
                ? Image.memory(_newPhoto!, fit: BoxFit.cover)
                : hasPhoto
                ? ProductThumbnail(product: existing!, size: 96)
                : ColoredBox(
                    color: colors.surface2,
                    child: Icon(LucideIcons.image, color: colors.ink3),
                  ),
          ),
        ),
        const SizedBox(width: 14),
        if (widget.canEdit)
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _saving ? null : _pickPhoto,
                  icon: const Icon(LucideIcons.imagePlus, size: 17),
                  label: Text(
                    hasPhoto ? 'Changer la photo' : 'Ajouter une photo',
                  ),
                ),
                if (hasPhoto)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() {
                            _newPhoto = null;
                            _removePhoto = existing?.imageKey != null;
                          }),
                    child: const Text('Retirer'),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  String? _validateQuantity(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return null;
    final quantity = parseQuantity(raw);
    if (quantity == null || quantity < Quantity.zero) {
      return 'Nombre positif, ex. 12,5';
    }
    if (quantity.scale > quantityScale) return '3 décimales au maximum';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final categories = ref.watch(categoriesProvider).value ?? const [];
    final taxRates = ref.watch(taxRatesProvider).value ?? const [];
    final priceTiers =
        ref.watch(priceTiersProvider).value ?? const <PriceTier>[];
    // Stock en ligne, si le compte peut le lire : état affiché sur la fiche.
    final existingStock = widget.existing == null || !widget.canReadStock
        ? null
        : ref.watch(stockByProductProvider).value?[widget.existing!.id];
    final bins = [
      for (final l in ref.watch(locationsProvider).value ?? const [])
        if (l.isBin) l,
    ];
    final roots = [
      for (final c in categories)
        if (c.parentId == null) c,
    ];

    InputDecoration deco(IconData icon, {String? helper}) => InputDecoration(
      prefixIcon: Icon(icon, size: 17),
      helperText: helper,
      helperMaxLines: 2,
      counterText: '',
    );
    final inputStyle = AmpereType.input.copyWith(color: colors.ink);

    return FormPanelFrame(
      formKey: _formKey,
      title: !widget.canEdit
          ? 'Fiche produit'
          : _isEdit
          ? 'Modifier le produit'
          : 'Nouveau produit',
      submitLabel: _isEdit ? 'Enregistrer' : 'Créer le produit',
      onSubmit: widget.canEdit ? _submit : null,
      saving: _saving,
      error: _error,
      children: [
        if (widget.canEdit || widget.existing?.imageKey != null) ...[
          const AmpereFieldLabel('Photo'),
          _photoSection(colors),
          formFieldGap,
        ],
        const AmpereFieldLabel('Désignation'),
        TextFormField(
          controller: _name,
          enabled: !_locked,
          autofocus: widget.canEdit && !_isEdit,
          maxLength: 150,
          style: inputStyle,
          decoration: deco(LucideIcons.package),
          validator: (v) => (v == null || v.trim().length < 2)
              ? 'Au moins 2 caractères'
              : null,
        ),
        formFieldGap,
        const AmpereFieldLabel('Référence'),
        TextFormField(
          controller: _sku,
          enabled: !_locked,
          maxLength: 50,
          autocorrect: false,
          style: AmpereType.mono.copyWith(color: colors.ink, fontSize: 15),
          decoration: deco(LucideIcons.hash),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'Référence obligatoire' : null,
        ),
        formFieldGap,
        const AmpereFieldLabel('Code-barres'),
        TextFormField(
          controller: _barcode,
          enabled: !_locked,
          maxLength: 64,
          autocorrect: false,
          enableSuggestions: false,
          style: AmpereType.mono.copyWith(color: colors.ink, fontSize: 15),
          decoration: deco(
            LucideIcons.scanBarcode,
            helper: _isEdit
                ? 'Corrigez un code mal saisi, ou scannez le bon'
                : 'Scannez le code fabricant — vide : un code interne est généré',
          ),
          validator: (v) => (v != null && RegExp(r'\s').hasMatch(v.trim()))
              ? 'Sans espace'
              : null,
        ),
        formFieldGap,
        const AmpereFieldLabel('Marque'),
        TextFormField(
          controller: _brand,
          enabled: !_locked,
          maxLength: 80,
          style: inputStyle,
          decoration: deco(LucideIcons.tag),
        ),
        formFieldGap,
        const AmpereFieldLabel('Unité de vente'),
        DropdownButtonFormField<ProductUnit>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: _unit,
          decoration: deco(LucideIcons.ruler),
          items: [
            for (final unit in ProductUnit.values)
              DropdownMenuItem(value: unit, child: Text(unit.label)),
          ],
          onChanged: _locked ? null : (v) => setState(() => _unit = v!),
        ),
        formFieldGap,
        const AmpereFieldLabel('Catégorie'),
        DropdownButtonFormField<String?>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: _categoryId,
          isExpanded: true,
          decoration: deco(LucideIcons.folderTree),
          items: [
            const DropdownMenuItem(value: null, child: Text('Aucune')),
            for (final root in roots) ...[
              if (root.isActive || root.id == _categoryId)
                DropdownMenuItem(value: root.id, child: Text(root.name)),
              for (final child in categories)
                if (child.parentId == root.id &&
                    (child.isActive || child.id == _categoryId))
                  DropdownMenuItem(
                    value: child.id,
                    child: Text('    ${child.name}'),
                  ),
            ],
          ],
          onChanged: _locked ? null : (v) => setState(() => _categoryId = v),
        ),
        formFieldGap,
        const AmpereFieldLabel('TVA'),
        DropdownButtonFormField<String?>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: _taxRateId,
          decoration: deco(LucideIcons.percent),
          items: [
            const DropdownMenuItem(value: null, child: Text('Non précisée')),
            for (final t in taxRates)
              if (t.isActive || t.id == _taxRateId)
                DropdownMenuItem(value: t.id, child: Text(t.name)),
          ],
          onChanged: _locked ? null : (v) => setState(() => _taxRateId = v),
        ),
        formFieldGap,
        const AmpereFieldLabel('Emplacement au dépôt'),
        DropdownButtonFormField<String?>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: _storageLocationId,
          isExpanded: true,
          decoration: deco(LucideIcons.mapPin),
          items: [
            const DropdownMenuItem(value: null, child: Text('Non rangé')),
            for (final bin in bins)
              if (bin.isActive || bin.id == _storageLocationId)
                DropdownMenuItem(
                  value: bin.id,
                  child: Text('${bin.code} — ${bin.name}'),
                ),
          ],
          onChanged: _locked
              ? null
              : (v) => setState(() => _storageLocationId = v),
        ),
        formFieldGap,
        if (!_isEdit) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _quantityField('Stock au magasin', _storeStock),
              const SizedBox(width: 12),
              _quantityField('Stock au dépôt', _depotStock),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Quantités présentes aujourd’hui. Ensuite, le stock ne change que par '
              'une opération (vente, réception, perte, inventaire).',
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
          ),
          formFieldGap,
        ] else if (existingStock != null) ...[
          const AmpereFieldLabel('Stock actuel'),
          Align(
            alignment: Alignment.centerLeft,
            child: StockStatusBadge(
              product: widget.existing!,
              stock: existingStock,
            ),
          ),
          formFieldGap,
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AmpereFieldLabel('Seuil minimum'),
                  TextFormField(
                    controller: _minThreshold,
                    enabled: !_locked,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: inputStyle,
                    decoration: InputDecoration(suffixText: _unit.short),
                    validator: _validateQuantity,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AmpereFieldLabel('Stock de sécurité'),
                  TextFormField(
                    controller: _safetyStock,
                    enabled: !_locked,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: inputStyle,
                    decoration: InputDecoration(suffixText: _unit.short),
                    validator: _validateQuantity,
                  ),
                ],
              ),
            ),
          ],
        ),
        formFieldGap,
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _allowBackorder,
          onChanged: _locked
              ? null
              : (v) => setState(() => _allowBackorder = v),
          title: const Text('Vente sans stock autorisée'),
          subtitle: const Text(
            'Par défaut, une vente qui rendrait le stock négatif est refusée',
          ),
        ),
        if (_isEdit && widget.canDisable)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _isActive,
            onChanged: _saving ? null : (v) => setState(() => _isActive = v),
            title: const Text('Produit actif'),
            subtitle: const Text(
              'Désactivé : il n’est plus proposé, son historique est conservé',
            ),
          ),
        formFieldGap,
        const AmpereFieldLabel('Description'),
        TextFormField(
          controller: _description,
          enabled: !_locked,
          maxLength: 1000,
          minLines: 2,
          maxLines: 5,
          style: inputStyle,
        ),
        formFieldGap,
        if (priceTiers.isNotEmpty) ...[
          if (!widget.canSetPrices)
            const AmpereFieldLabel('Prix de vente (HT)'),
          _pricesSection(colors, priceTiers),
        ],
      ],
    );
  }
}
