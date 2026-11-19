import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../purchases/application/purchase_cart.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/data/auth_models.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/photos.dart';
import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/catalog_controller.dart';
import '../../stock/application/stock_controller.dart';
import '../../stock/presentation/stock_status.dart';
import '../data/catalog_models.dart';
import 'price_history.dart';
import '../../suppliers/application/suppliers_controller.dart';
import '../../suppliers/data/suppliers_api.dart';
import '../../suppliers/data/suppliers_models.dart';
import '../../scan/presentation/scan_screen.dart';
import 'product_photo.dart';
import 'prospects_dialog.dart';

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
    this.canReadSuppliers = false,
    this.canSetPrices = false,
    this.canContactCustomers = false,
    this.initialBarcode,
    this.initialName,
    this.initialSupplierName,
    this.forPurchase = false,
  });

  /// Fournisseur pré-rempli (créé depuis un achat, 2026-11-19).
  final String? initialSupplierName;

  /// Ouvert DEPUIS l'achat : pas de stock ici, il se saisit sur la ligne.
  final bool forPurchase;

  /// Nouveau produit : nom déjà dicté (assistant, 2026-10-05).
  final String? initialName;

  final Product? existing;

  /// Nouveau produit : code-barres déjà lu (ajout rapide depuis l'accueil).
  final String? initialBarcode;
  final bool canEdit;
  final bool canDisable;
  final bool canReadStock;

  /// ADMIN|MAGASINIER + `supplier.read` : le fournisseur principal est proposé.
  /// Sans ce droit, le serveur masque déjà le champ — on ne l'affiche pas.
  final bool canReadSuppliers;

  /// ADMIN + `price.manage` : les prix sont modifiables ; sinon lecture seule.
  final bool canSetPrices;

  /// ADMIN + `customer.read` : « Clients à prévenir » (P2 n°23).
  final bool canContactCustomers;

  @override
  ConsumerState<ProductForm> createState() => _ProductFormState();
}

/// Stock de départ : réglé au fournisseur ?
enum _Paid { all, part, none }

class _ProductFormState extends ConsumerState<ProductForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _sku;
  late final TextEditingController _name;
  late final TextEditingController _barcode;
  late final TextEditingController _brand;
  late final TextEditingController _description;
  late final TextEditingController _minThreshold;

  /// Un champ de prix par tarif, créé à l'arrivée de la liste des tarifs.
  final Map<String, TextEditingController> _prices = {};

  /// Prix d'achat INITIAL (P1 bis n°21f) : saisi à la création, ou tant que le
  /// coût est inconnu ; ensuite seules les réceptions le changent (règle 5).
  late final _cost = TextEditingController(
    text: widget.existing?.lastPurchasePriceHt == null
        ? ''
        : formatDA(widget.existing!.lastPurchasePriceHt!, withSymbol: false),
  );

  /// Saisi par l'admin ; le serveur le refuse (409) dès qu'une réception
  /// existe pour ce produit — elle fixe alors le coût (règle 5).
  bool get _costEditable => widget.canSetPrices;

  /// Stock présent à la saisie (création seulement) : devient un mouvement
  /// « stock initial » côté serveur, jamais une quantité écrite directement.
  final _storeStock = TextEditingController();
  final _depotStock = TextEditingController();
  late ProductUnit _unit;
  String? _categoryId;
  String? _storageLocationId;
  String? _mainSupplierId;
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
    // Nouveau produit : référence proposée d'office (2026-10-28), modifiable.
    _sku = TextEditingController(
      text:
          p?.sku ??
          'P${DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase()}',
    );
    _name = TextEditingController(text: p?.name ?? widget.initialName ?? '');
    _barcode = TextEditingController(
      text: p?.barcode ?? widget.initialBarcode ?? '',
    );
    _brand = TextEditingController(text: p?.brand ?? '');
    _description = TextEditingController(text: p?.description ?? '');
    _minThreshold = TextEditingController(
      text: p == null ? '' : formatQuantity(p.minThreshold),
    );
    _unit = p?.unit ?? ProductUnit.piece;
    _categoryId = p?.categoryId;
    _storageLocationId = p?.storageLocationId;
    _mainSupplierId = p?.mainSupplierId;
    _supplierName.text =
        p?.mainSupplierName ?? widget.initialSupplierName ?? '';
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
      _cost,
      _minThreshold,
      _storeStock,
      _depotStock,
      _supplierName,
      _paidPart,
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

  /// Nom tapé du fournisseur (demande MEDMEDBEN du 2026-11-15).
  final _supplierName = TextEditingController();

  /// Fournisseur : on TAPE son nom, les fournisseurs connus sont proposés.
  /// Un nom inconnu crée le fournisseur (son nom seulement) à l'enregistrement
  /// — ses coordonnées se complètent ensuite dans « Fournisseurs ». Le
  /// fournisseur se change à tout moment (achat suivant chez un autre).
  Widget _supplierField(InputDecoration Function(IconData) deco) {
    final items =
        ref.watch(supplierSearchProvider('')).value ?? const <Supplier>[];
    return Autocomplete<Supplier>(
      initialValue: TextEditingValue(text: _supplierName.text),
      displayStringForOption: (s) => s.name,
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        return q.isEmpty
            ? items.take(8)
            : items.where((s) => s.name.toLowerCase().contains(q)).take(8);
      },
      onSelected: (s) {
        _supplierName.text = s.name;
        _mainSupplierId = s.id;
      },
      fieldViewBuilder: (context, controller, focus, onSubmit) => TextFormField(
        key: const ValueKey('champ-fournisseur'),
        controller: controller,
        focusNode: focus,
        enabled: !_locked,
        maxLength: 120,
        decoration: deco(LucideIcons.truck).copyWith(
          hintText: 'Nom du fournisseur',
          helperText: 'Nouveau nom : le fournisseur est créé',
          counterText: '',
        ),
        onChanged: (v) {
          _supplierName.text = v;
          _mainSupplierId = null;
        },
        validator: (v) =>
            (v ?? '').trim().isEmpty ? 'Fournisseur obligatoire' : null,
        onFieldSubmitted: (_) => onSubmit(),
      ),
    );
  }

  /// Fournisseur tapé → son id : connu (même nom), sinon CRÉÉ avec ce nom.
  /// Vide : aucun fournisseur.
  Future<String?> _resolveSupplier() async {
    final name = _supplierName.text.trim();
    if (name.isEmpty) return null;
    if (_mainSupplierId != null) return _mainSupplierId;
    final known =
        (ref.read(supplierSearchProvider('')).value ?? const <Supplier>[])
            .where((s) => s.name.trim().toLowerCase() == name.toLowerCase())
            .firstOrNull;
    if (known != null) return known.id;
    final created = await ref.read(suppliersApiProvider).create({'name': name});
    ref.invalidate(supplierSearchProvider);
    return created.id;
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
    'storageLocationId': _storageLocationId,
    if (widget.canReadSuppliers) 'mainSupplierId': _mainSupplierId,
    'minThreshold': _quantity(_minThreshold),
    'allowBackorder': _allowBackorder,
    if (_isEdit && widget.canDisable) 'isActive': _isActive,
    if (_costEditable) 'purchasePriceHt': parseDA(_cost.text),
  };

  static Map<String, Object?> _valuesOf(Product p) => {
    'sku': p.sku,
    'name': p.name,
    'barcode': p.barcode,
    'brand': p.brand,
    'description': p.description,
    'unit': p.unit.code,
    'categoryId': p.categoryId,
    'storageLocationId': p.storageLocationId,
    'mainSupplierId': p.mainSupplierId,
    'minThreshold': quantityToJson(p.minThreshold),
    'allowBackorder': p.allowBackorder,
    'isActive': p.isActive,
    'purchasePriceHt': p.lastPurchasePriceHt,
  };

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (widget.canReadSuppliers) {
      try {
        _mainSupplierId = await _resolveSupplier();
      } on ApiException catch (error) {
        if (!mounted) return;
        setState(
          () => _error = error.isOffline
              ? 'Nouveau fournisseur : à créer en ligne. Videz le champ '
                    'fournisseur pour enregistrer le produit hors ligne.'
              : error.userMessage,
        );
        return;
      }
      if (!mounted) return;
    }
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
        // Stock de départ avec fournisseur et prix = un ACHAT (2026-11-19) :
        // il entre par l'achat (dette ou réglé), pas en « stock initial ».
        if (initialStock.isNotEmpty && !_viaPurchase)
          'initialStock': initialStock,
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
      if (existing == null && _viaPurchase) await _purchaseStock(saved);
      if (mounted) Navigator.of(context).pop(saved);
    } on PhotoNotSaved catch (partial) {
      // Le produit est enregistré : on ferme sur lui, et on dit que la photo
      // n'est pas passée (la rajouter depuis sa fiche).
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(partial.product);
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(partial.message),
        ),
      );
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
    String key,
  ) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AmpereFieldLabel(label),
        TextFormField(
          key: ValueKey(key),
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

  /// Le stock saisi passe par un achat : fournisseur connu, prix > 0.
  bool get _viaPurchase =>
      !widget.forPurchase &&
      widget.canReadSuppliers &&
      _stockTotal > Quantity.zero &&
      (parseDA(_cost.text) ?? 0) > 0;

  /// Ligne d'achat de ce produit : où va le stock saisi.
  PurchaseLine _lineFor(Product product) {
    final store = parseQuantity(_storeStock.text) ?? Quantity.zero;
    final depot = parseQuantity(_depotStock.text) ?? Quantity.zero;
    final cost = parseDA(_cost.text) ?? 0;
    if (store > Quantity.zero && depot > Quantity.zero) {
      return PurchaseLine(
        product: product,
        unitPriceHt: cost,
        destination: PurchaseDestination.both,
        toStore: store,
        toDepot: depot,
      );
    }
    return PurchaseLine(
      product: product,
      unitPriceHt: cost,
      destination: store > Quantity.zero
          ? PurchaseDestination.store
          : PurchaseDestination.depot,
      quantity: store > Quantity.zero ? store : depot,
    );
  }

  /// Achat du stock de départ, réglé / en partie / pas encore.
  Future<void> _purchaseStock(Product product) async {
    final amount = _stockAmount;
    final paid = !_canPay
        ? 0
        : switch (_paid) {
            _Paid.all => amount,
            _Paid.none => 0,
            _Paid.part => parseDA(_paidPart.text) ?? 0,
          };
    try {
      await ref.read(purchaseSubmitProvider)(
        cart: PurchaseCart(
          id: ref.read(uuidProvider).v7(),
          supplierId: _mainSupplierId,
          supplierName: _supplierName.text.trim(),
          lines: [_lineFor(product)],
        ),
        paidAmount: paid,
        clearCart: false,
      );
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Produit créé, mais son achat n’est pas passé : '
              '${error.userMessage}',
            ),
          ),
        );
      }
    }
  }

  /// « Ajouter au panier d'achat » : le produit est créé (sans stock), puis
  /// posé dans le brouillon d'achat avec les quantités saisies.
  Future<void> _addToPurchaseCart() async {
    if (!_formKey.currentState!.validate()) return;
    try {
      _mainSupplierId = await _resolveSupplier();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.userMessage);
      return;
    }
    if (!mounted) return;
    final values = _values();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref.read(catalogActionsProvider).saveProduct(null, {
        for (final e in values.entries)
          if (e.value != null) e.key: e.value,
      }, prices: _changedPrices());
      final cart = ref.read(purchaseCartProvider.notifier);
      if (ref.read(purchaseCartProvider).supplierId == null) {
        cart.setSupplier(_mainSupplierId, _supplierName.text.trim());
      }
      final line = _lineFor(saved);
      cart.add(
        saved,
        unitPriceHt: line.unitPriceHt,
        destination: line.destination,
        quantity: line.quantity,
        toStore: line.toStore,
        toDepot: line.toDepot,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${saved.name} ajouté au panier d’achat '
            '(${ref.read(purchaseCartProvider).lines.length} produit(s)) — '
            'Achats → Nouvel achat pour valider.',
          ),
        ),
      );
      Navigator.of(context).pop(saved);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.userMessage;
          _saving = false;
        });
      }
    }
  }

  /// Stock saisi à la création = un ACHAT (2026-11-19) : prix d'achat ×
  /// quantité (magasin + dépôt). Est-il réglé au fournisseur ?
  _Paid _paid = _Paid.all;

  /// « Garder le prix » vient d'être choisi.
  bool _reviewDone = false;
  final _paidPart = TextEditingController();

  Quantity get _stockTotal =>
      (parseQuantity(_storeStock.text) ?? Quantity.zero) +
      (parseQuantity(_depotStock.text) ?? Quantity.zero);

  int get _stockAmount {
    final cost = parseDA(_cost.text) ?? 0;
    final total = _stockTotal;
    if (cost <= 0 || total <= Quantity.zero) return 0;
    return (total * Quantity.fromInt(cost)).round().toBigInt().toInt();
  }

  bool get _canPay => switch (ref.read(authControllerProvider).value) {
    AuthSignedIn(:final user) =>
      user.hasRole('ADMIN') && user.can('supplier.payment.create'),
    _ => false,
  };

  Widget _paidSection(AmpereColors colors) {
    final amount = _stockAmount;
    if (amount == 0 || !widget.canReadSuppliers) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: colors.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.line),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Achat : ${formatDA(amount)} (prix d’achat × quantité)',
                style: AmpereType.bodyStrong.copyWith(color: colors.ink),
              ),
              if (_canPay) ...[
                const SizedBox(height: 8),
                SegmentedButton<_Paid>(
                  segments: const [
                    ButtonSegment(value: _Paid.all, label: Text('Réglé')),
                    ButtonSegment(value: _Paid.part, label: Text('En partie')),
                    ButtonSegment(value: _Paid.none, label: Text('Pas encore')),
                  ],
                  selected: {_paid},
                  onSelectionChanged: (s) => setState(() => _paid = s.first),
                ),
                if (_paid == _Paid.part) ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _paidPart,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Somme donnée au fournisseur',
                      suffixText: 'DA',
                    ),
                    validator: (v) {
                      final a = parseDA(v ?? '');
                      return a == null || a <= 0 || a > amount
                          ? 'Entre 1 et ${formatDA(amount)}'
                          : null;
                    },
                  ),
                ],
              ] else
                Text(
                  'Le montant va en dette chez le fournisseur.',
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Prix d'achat : modifiable tant qu'il est inconnu (admin), sinon affiché
  /// — c'est le coût de la marge et le plancher du prix de vente.
  Widget _costSection(AmpereColors colors, TextStyle inputStyle) {
    final known = widget.existing?.lastPurchasePriceHt;
    if (!_costEditable) {
      return Text(
        known == null
            ? 'Prix d’achat : inconnu (fixé par la première réception)'
            : 'Prix d’achat : ${formatDA(known)}',
        style: AmpereType.body.copyWith(color: colors.ink),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AmpereFieldLabel(
          _isEdit ? 'Prix d’achat' : 'Prix d’achat (obligatoire)',
        ),
        TextFormField(
          key: const ValueKey('champ-prix-achat'),
          controller: _cost,
          enabled: !_saving,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: inputStyle,
          decoration: const InputDecoration(suffixText: 'DA'),
          validator: (v) {
            final raw = v?.trim() ?? '';
            // Obligatoire à la création : c'est le coût de la marge et le
            // plancher du prix de vente (demande MEDMEDBEN du 2026-11-15).
            if (raw.isEmpty) return _isEdit ? null : 'Prix d’achat obligatoire';
            final amount = parseDA(raw);
            return amount == null || amount < 0 ? 'Montant invalide' : null;
          },
        ),
      ],
    );
  }

  /// Tarifs, puis (produit existant) leur historique (P1 bis n°21n).
  Widget _pricesSection(AmpereColors colors, List<PriceTier> tiers) {
    final product = widget.existing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _priceFields(colors, tiers),
        if (product != null)
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: () => _showPriceHistory(product),
                icon: const Icon(Icons.history, size: 18),
                label: const Text('Historique des prix'),
              ),
              if (widget.canContactCustomers && product.categoryId != null)
                TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => ProspectsDialog(product: product),
                  ),
                  icon: const Icon(Icons.campaign_outlined, size: 18),
                  label: const Text('Clients à prévenir'),
                ),
            ],
          ),
      ],
    );
  }

  Future<void> _showPriceHistory(Product product) =>
      showProductPriceHistory(context, ref, product);

  Widget _priceFields(AmpereColors colors, List<PriceTier> tiers) {
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
                AmpereFieldLabel('Prix ${tier.name}'),
                TextFormField(
                  key: ValueKey('prix-${tier.id}'),
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
    final Uint8List? photo;
    try {
      photo = await ref.read(pickPhotoProvider)();
    } on FormatException {
      _photoProblem('Photo illisible : choisissez une photo JPEG ou PNG.');
      return;
    } catch (error) {
      // Accès aux photos refusé, sélecteur indisponible… : on le DIT
      // toujours — jamais un bouton qui ne fait rien.
      _photoProblem('Impossible d’ouvrir la photo ($error).');
      return;
    }
    if (!mounted) return;
    if (photo == null) return;
    setState(() {
      _newPhoto = photo;
      _removePhoto = false;
    });
  }

  void _photoProblem(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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

    Widget field(String label, Widget input) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [AmpereFieldLabel(label), input, formFieldGap],
    );

    // ── L'essentiel : ce qu'il faut pour vendre ────────────────────────
    final essentials = <Widget>[
      field(
        'Désignation *',
        TextFormField(
          key: const ValueKey('champ-nom'),
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
      ),
      field(
        'Unité de vente',
        DropdownButtonFormField<ProductUnit>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: _unit,
          decoration: deco(LucideIcons.ruler),
          items: [
            for (final unit in selectableUnits)
              DropdownMenuItem(value: unit, child: Text(unit.label)),
            // Produit enregistré avec une ancienne unité : elle reste
            // affichée telle quelle (rien n'est converti).
            if (!selectableUnits.contains(_unit))
              DropdownMenuItem(value: _unit, child: Text(_unit.label)),
          ],
          onChanged: _locked ? null : (v) => setState(() => _unit = v!),
        ),
      ),
      // Fournisseur et prix d'achat OBLIGATOIRES, avec les premiers champs
      // (demande MEDMEDBEN du 2026-11-19).
      if (widget.canReadSuppliers) field('Fournisseur *', _supplierField(deco)),
      _costSection(colors, inputStyle),
      formFieldGap,
      // Prix d'achat changé à un achat (2026-11-19) : revoir le prix de vente,
      // ou le GARDER tel quel d'un geste.
      if (widget.existing?.priceReviewNeeded == true && !_reviewDone) ...[
        Material(
          color: colors.infoBg,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                Icon(LucideIcons.tag, size: 16, color: colors.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Le prix d’achat a changé au dernier achat : modifiez le '
                    'prix de vente, ou gardez-le.',
                    style: AmpereType.meta.copyWith(color: colors.ink),
                  ),
                ),
                if (widget.canSetPrices)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () async {
                            await ref
                                .read(catalogActionsProvider)
                                .keepPrice(widget.existing!.id);
                            if (mounted) setState(() => _reviewDone = true);
                          },
                    child: const Text('Garder le prix'),
                  ),
              ],
            ),
          ),
        ),
        formFieldGap,
      ],
      if (priceTiers.isNotEmpty) ...[
        if (!widget.canSetPrices) const AmpereFieldLabel('Prix de vente'),
        _pricesSection(colors, priceTiers),
        formFieldGap,
      ],
      if (!_isEdit && !widget.forPurchase) ...[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _quantityField(
              'Stock au magasin',
              _storeStock,
              'champ-stock-magasin',
            ),
            const SizedBox(width: 12),
            _quantityField('Stock au dépôt', _depotStock, 'champ-stock-depot'),
          ],
        ),
        formFieldGap,
        _paidSection(colors),
      ] else if (existingStock != null)
        field(
          'Stock actuel',
          Align(
            alignment: Alignment.centerLeft,
            child: StockStatusBadge(
              product: widget.existing!,
              stock: existingStock,
            ),
          ),
        ),
    ];

    // ── Identification ─────────────────────────────────────────────────
    final identity = <Widget>[
      field(
        'Référence *',
        TextFormField(
          key: const ValueKey('champ-reference'),
          controller: _sku,
          enabled: !_locked,
          maxLength: 50,
          autocorrect: false,
          style: AmpereType.mono.copyWith(color: colors.ink, fontSize: 15),
          decoration: deco(LucideIcons.hash),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'Référence obligatoire' : null,
        ),
      ),
      field(
        'Code-barres',
        TextFormField(
          key: const ValueKey('champ-code-barres'),
          controller: _barcode,
          enabled: !_locked,
          maxLength: 64,
          autocorrect: false,
          enableSuggestions: false,
          style: AmpereType.mono.copyWith(color: colors.ink, fontSize: 15),
          decoration:
              deco(
                LucideIcons.scanBarcode,
                helper: _isEdit ? null : 'Vide : un code est généré',
              ).copyWith(
                suffixIcon: _locked
                    ? null
                    : CameraScanButton(onCode: (code) => _barcode.text = code),
              ),
          validator: (v) => (v != null && RegExp(r'\s').hasMatch(v.trim()))
              ? 'Sans espace'
              : null,
        ),
      ),
      field(
        'Catégorie',
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
      ),
      field(
        'Marque',
        TextFormField(
          key: const ValueKey('champ-marque'),
          controller: _brand,
          enabled: !_locked,
          maxLength: 80,
          style: inputStyle,
          decoration: deco(LucideIcons.tag),
        ),
      ),
    ];

    // ── Plus de détails : tout le reste, facultatif ───────────────────
    final details = <Widget>[
      if (widget.canEdit || widget.existing?.imageKey != null)
        field('Photo', _photoSection(colors)),
      // Un magasin et un dépôt (2026-11-15) : la liste des rangements ne
      // s'affiche que si des emplacements ont été créés.
      if (bins.isNotEmpty || _storageLocationId != null)
        field(
          'Emplacement au dépôt',
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
        ),
      // UN seul seuil (décision MEDMEDBEN du 2026-10-05) : il déclenche
      // l'alerte et la proposition de réapprovisionnement.
      field(
        'Seuil minimum',
        TextFormField(
          key: const ValueKey('champ-seuil'),
          controller: _minThreshold,
          enabled: !_locked,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: inputStyle,
          decoration: InputDecoration(suffixText: _unit.short),
          validator: _validateQuantity,
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _allowBackorder,
        onChanged: _locked ? null : (v) => setState(() => _allowBackorder = v),
        title: const Text('Vente sans stock autorisée'),
      ),
      if (_isEdit && widget.canDisable)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _isActive,
          onChanged: _saving ? null : (v) => setState(() => _isActive = v),
          title: const Text('Produit actif'),
        ),
      formFieldGap,
      field(
        'Description',
        TextFormField(
          key: const ValueKey('champ-description'),
          controller: _description,
          enabled: !_locked,
          maxLength: 1000,
          minLines: 2,
          maxLines: 5,
          style: inputStyle,
        ),
      ),
    ];

    Widget block(IconData icon, String title, List<Widget> children) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 15, color: colors.accent),
            const SizedBox(width: 8),
            Text(
              title.toUpperCase(),
              style: AmpereType.label.copyWith(color: colors.ink2),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    );

    return FormPanelFrame(
      formKey: _formKey,
      title: !widget.canEdit
          ? 'Fiche produit'
          : _isEdit
          ? 'Modifier le produit'
          : 'Nouveau produit',
      submitLabel: _isEdit ? 'Enregistrer' : 'Créer le produit',
      // Optionnel : le produit va dans le PANIER D'ACHAT (brouillon) pour
      // en ajouter d'autres avant de valider l'achat (2026-11-19).
      headerAction: !_isEdit && !widget.forPurchase && widget.canReadSuppliers
          ? TextButton.icon(
              onPressed: _saving ? null : _addToPurchaseCart,
              icon: const Icon(LucideIcons.shoppingCart, size: 16),
              label: const Text('Ajouter au panier d’achat'),
            )
          : null,
      onSubmit: widget.canEdit ? _submit : null,
      saving: _saving,
      error: _error,
      children: [
        // Deux colonnes dans la grande fenêtre ; une seule sur téléphone.
        LayoutBuilder(
          builder: (context, box) {
            final left = block(LucideIcons.sparkles, 'L’essentiel', essentials);
            final right = block(
              LucideIcons.fingerprint,
              'Identification',
              identity,
            );
            if (box.maxWidth < 640) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [left, right],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: left),
                const SizedBox(width: 28),
                Expanded(child: right),
              ],
            );
          },
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.line),
          ),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: _isEdit,
              maintainState: true,
              tilePadding: const EdgeInsets.symmetric(horizontal: 14),
              childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              leading: Icon(
                LucideIcons.slidersHorizontal,
                size: 17,
                color: colors.ink2,
              ),
              title: Text(
                'Plus de détails',
                style: AmpereType.bodyStrong.copyWith(color: colors.ink),
              ),
              subtitle: Text(
                'Facultatif — photo, fournisseur, rangement, seuil, achat',
                style: AmpereType.meta.copyWith(color: colors.ink3),
              ),
              children: details,
            ),
          ),
        ),
      ],
    );
  }
}
