import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/offline_write.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../catalog/presentation/catalog_screen.dart';
import '../../catalog/presentation/product_form.dart';
import '../../suppliers/application/suppliers_controller.dart';
import '../../suppliers/data/suppliers_models.dart';
import '../../suppliers/presentation/suppliers_screen.dart';
import '../application/purchase_cart.dart';

/// Ce qui est payé au fournisseur à l'achat.
enum _Paid { all, part, none }

/// NOUVEL ACHAT (demande MEDMEDBEN du 2026-11-19) : un PANIER D'ACHAT complet
/// — fournisseur (ou le créer), ses produits (ou en créer), où ranger, ce
/// qu'on paie. À la validation, tout entre en stock d'un coup ; le non-payé
/// devient la dette du fournisseur.
Future<void> openDirectPurchase(BuildContext context, AuthUser user) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => DirectPurchaseScreen(user: user)),
    );

class DirectPurchaseScreen extends ConsumerStatefulWidget {
  const DirectPurchaseScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<DirectPurchaseScreen> createState() =>
      _DirectPurchaseScreenState();
}

class _DirectPurchaseScreenState extends ConsumerState<DirectPurchaseScreen> {
  _Paid _paid = _Paid.none;
  final _partial = TextEditingController();
  bool _allProducts = false;
  bool _saving = false;
  String? _error;

  bool get _canPay =>
      widget.user.hasRole('ADMIN') &&
      widget.user.can('supplier.payment.create');

  @override
  void dispose() {
    _partial.dispose();
    super.dispose();
  }

  Future<void> _createSupplier() async {
    final saved = await openFormPanel<Supplier>(
      context,
      SupplierForm(canSetDebt: widget.user.hasRole('ADMIN')),
    );
    if (saved == null || !mounted) return;
    ref.invalidate(supplierSearchProvider);
    ref.read(purchaseCartProvider.notifier).setSupplier(saved.id, saved.name);
  }

  Future<void> _createProduct() async {
    final rights = CatalogRights(widget.user);
    final cart = ref.read(purchaseCartProvider);
    final saved = await openFormPanel<Product>(
      context,
      ProductForm(
        canEdit: rights.canWriteProducts,
        canDisable: rights.canDisableProducts,
        canReadStock: rights.canReadStock,
        canReadSuppliers: rights.canReadSuppliers,
        canSetPrices: rights.canSetPrices,
        initialSupplierName: cart.supplierName,
        // Dans un achat, la quantité se saisit sur la ligne du panier.
        forPurchase: true,
      ),
    );
    if (saved == null || !mounted) return;
    ref.read(purchaseCartProvider.notifier).add(saved);
  }

  Future<void> _submit(PurchaseCart cart) async {
    if (cart.supplierId == null) {
      setState(() => _error = 'Choisissez le fournisseur.');
      return;
    }
    if (cart.isEmpty) {
      setState(() => _error = 'Ajoutez au moins un produit.');
      return;
    }
    for (final l in cart.lines) {
      if (l.total <= Quantity.zero) {
        setState(() => _error = 'Quantité manquante : ${l.product.name}.');
        return;
      }
      // Prix d'achat obligatoire (> 0) : c'est le coût de la marge.
      if (l.unitPriceHt <= 0) {
        setState(() => _error = 'Prix d’achat manquant : ${l.product.name}.');
        return;
      }
    }
    final paid = !_canPay
        ? 0
        : switch (_paid) {
            _Paid.all => cart.total,
            _Paid.none => 0,
            _Paid.part => parseDA(_partial.text) ?? -1,
          };
    if (paid < 0 || paid > cart.total) {
      setState(
        () => _error =
            'Montant payé : entre 0 et ${formatDA(cart.total)} (le total).',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final outcome = await ref.read(purchaseSubmitProvider)(
        cart: cart,
        paidAmount: paid,
      );
      if (!mounted) return;
      final rest = cart.total - paid;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(switch (outcome) {
            Applied(value: final numbers) =>
              'Achat enregistré (${numbers.join(', ')}) : en stock. '
                  '${rest > 0 ? 'Dette : ${formatDA(rest)}.' : 'Payé en entier.'}',
            Queued() =>
              'Achat enregistré HORS LIGNE : il entrera en stock à la '
                  'synchronisation.',
          }),
        ),
      );
      Navigator.of(context).pop();
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
    final cart = ref.watch(purchaseCartProvider);
    final notifier = ref.read(purchaseCartProvider.notifier);
    final suppliers =
        ref.watch(supplierSearchProvider('')).value ?? const <Supplier>[];
    final products =
        ref.watch(activeProductsProvider).value ?? const <Product>[];
    final supplierName = cart.supplierName?.trim().toLowerCase();
    // Ses produits d'abord : ceux dont il est le fournisseur principal.
    final offered = [
      for (final p in products)
        if (_allProducts ||
            supplierName == null ||
            (p.mainSupplierName?.trim().toLowerCase() == supplierName))
          p,
    ];
    final canCreateProduct = CatalogRights(widget.user).canWriteProducts;
    final rest = switch (_paid) {
      _Paid.all => 0,
      _Paid.none => cart.total,
      _Paid.part => (cart.total - (parseDA(_partial.text) ?? 0)).clamp(
        0,
        cart.total,
      ),
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nouvel achat'),
        actions: [
          if (!cart.isEmpty)
            TextButton.icon(
              onPressed: _saving ? null : notifier.clear,
              icon: const Icon(LucideIcons.trash2, size: 16),
              label: const Text('Vider'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // ── 1. Fournisseur ─────────────────────────────────────────────
          Text(
            'FOURNISSEUR',
            style: AmpereType.label.copyWith(color: colors.ink3),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Autocomplete<Supplier>(
                  key: ValueKey('fournisseur-${cart.supplierId}'),
                  initialValue: TextEditingValue(text: cart.supplierName ?? ''),
                  displayStringForOption: (s) => s.name,
                  optionsBuilder: (v) {
                    final q = v.text.trim().toLowerCase();
                    return suppliers
                        .where((s) => s.name.toLowerCase().contains(q))
                        .take(10);
                  },
                  onSelected: (s) => notifier.setSupplier(s.id, s.name),
                  fieldViewBuilder: (context, controller, focus, onSubmit) =>
                      TextField(
                        controller: controller,
                        focusNode: focus,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(LucideIcons.truck, size: 18),
                          hintText: 'Chercher le fournisseur',
                        ),
                      ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _saving ? null : _createSupplier,
                icon: const Icon(LucideIcons.userPlus, size: 16),
                label: const Text('Créer'),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // ── 2. Produits ────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: Text(
                  'PRODUITS',
                  style: AmpereType.label.copyWith(color: colors.ink3),
                ),
              ),
              if (cart.supplierId != null)
                FilterChip(
                  label: const Text('Tous les produits'),
                  selected: _allProducts,
                  onSelected: (v) => setState(() => _allProducts = v),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Autocomplete<Product>(
                  key: ValueKey('produit-${cart.lines.length}-$_allProducts'),
                  displayStringForOption: (p) => p.name,
                  optionsBuilder: (v) {
                    final q = v.text.trim().toLowerCase();
                    return offered
                        .where(
                          (p) =>
                              q.isEmpty ||
                              p.name.toLowerCase().contains(q) ||
                              p.sku.toLowerCase().contains(q) ||
                              p.barcode == q,
                        )
                        .take(12);
                  },
                  onSelected: notifier.add,
                  fieldViewBuilder: (context, controller, focus, onSubmit) =>
                      TextField(
                        controller: controller,
                        focusNode: focus,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(LucideIcons.search, size: 18),
                          hintText: cart.supplierId == null || _allProducts
                              ? 'Ajouter un produit'
                              : 'Produits de ${cart.supplierName}',
                        ),
                      ),
                ),
              ),
              if (canCreateProduct) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _saving ? null : _createProduct,
                  icon: const Icon(LucideIcons.packagePlus, size: 16),
                  label: const Text('Nouveau produit'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (cart.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Le panier d’achat est vide.',
                textAlign: TextAlign.center,
                style: AmpereType.body.copyWith(color: colors.ink3),
              ),
            ),
          for (final (i, line) in cart.lines.indexed)
            _LineCard(
              key: ValueKey(line.product.id),
              line: line,
              onChanged: (l) => notifier.update(i, l),
              onRemove: () => notifier.remove(i),
            ),

          // ── 3. Total et paiement ───────────────────────────────────────
          if (!cart.isEmpty) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'TOTAL DE L’ACHAT',
                            style: AmpereType.label.copyWith(
                              color: colors.ink3,
                            ),
                          ),
                        ),
                        Text(
                          formatDA(cart.total),
                          style: AmpereType.h2.copyWith(
                            color: colors.ink,
                            fontFeatures: AmpereType.tabular,
                          ),
                        ),
                      ],
                    ),
                    if (_canPay) ...[
                      const SizedBox(height: 12),
                      SegmentedButton<_Paid>(
                        segments: const [
                          ButtonSegment(
                            value: _Paid.all,
                            icon: Icon(LucideIcons.circleCheck, size: 16),
                            label: Text('Payé en totalité'),
                          ),
                          ButtonSegment(
                            value: _Paid.part,
                            icon: Icon(LucideIcons.circleDot, size: 16),
                            label: Text('En partie'),
                          ),
                          ButtonSegment(
                            value: _Paid.none,
                            icon: Icon(LucideIcons.circle, size: 16),
                            label: Text('Pas payé'),
                          ),
                        ],
                        selected: {_paid},
                        onSelectionChanged: (s) =>
                            setState(() => _paid = s.first),
                      ),
                      if (_paid == _Paid.part) ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: _partial,
                          autofocus: true,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Somme donnée au fournisseur',
                            suffixText: 'DA',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Text(
                        rest == 0
                            ? 'Payé en entier — aucune dette.'
                            : 'Va en dette chez le fournisseur : ${formatDA(rest)}',
                        style: AmpereType.bodyStrong.copyWith(
                          color: rest == 0 ? colors.ok : colors.warn,
                        ),
                      ),
                    ] else
                      Text(
                        'Le total va en dette chez le fournisseur (le paiement '
                        'se fait par l’administrateur).',
                        style: AmpereType.meta.copyWith(color: colors.ink3),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: AmpereType.body.copyWith(color: colors.error)),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: _saving || cart.isEmpty ? null : () => _submit(cart),
            icon: const Icon(LucideIcons.packageCheck, size: 18),
            label: Text(
              _saving ? 'Enregistrement…' : 'Valider l’achat — entrée en stock',
            ),
          ),
        ],
      ),
    );
  }
}

/// Une ligne : prix d'achat, où ranger, combien.
class _LineCard extends StatefulWidget {
  const _LineCard({
    super.key,
    required this.line,
    required this.onChanged,
    required this.onRemove,
  });

  final PurchaseLine line;
  final ValueChanged<PurchaseLine> onChanged;
  final VoidCallback onRemove;

  @override
  State<_LineCard> createState() => _LineCardState();
}

class _LineCardState extends State<_LineCard> {
  late final _price = TextEditingController(
    text: formatDA(widget.line.unitPriceHt, withSymbol: false),
  );
  late final _qty = TextEditingController(text: _show(widget.line.quantity));
  late final _store = TextEditingController(text: _show(widget.line.toStore));
  late final _depot = TextEditingController(text: _show(widget.line.toDepot));

  static String _show(Quantity q) =>
      q == Quantity.zero ? '' : formatQuantity(q);

  @override
  void dispose() {
    for (final c in [_price, _qty, _store, _depot]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Saisie → ligne ; une quantité ou un prix négatif est refusé (2026-11-19).
  void _push({PurchaseDestination? destination}) {
    Quantity q(TextEditingController c) {
      final v = parseQuantity(c.text);
      return v == null || v < Quantity.zero ? Quantity.zero : v;
    }

    final price = parseDA(_price.text);
    widget.onChanged(
      widget.line.copyWith(
        unitPriceHt: price == null || price < 0 ? 0 : price,
        destination: destination,
        quantity: q(_qty),
        toStore: q(_store),
        toDepot: q(_depot),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final line = widget.line;
    final unit = line.product.unit.short;
    String? positive(String? v) {
      final raw = v?.trim() ?? '';
      if (raw.isEmpty) return null;
      final q = parseQuantity(raw);
      return q == null || q < Quantity.zero ? 'Quantité positive' : null;
    }

    Widget qtyField(String label, TextEditingController c) => Expanded(
      child: TextFormField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        autovalidateMode: AutovalidateMode.onUserInteraction,
        validator: positive,
        decoration: InputDecoration(labelText: label, suffixText: unit),
        onChanged: (_) => _push(),
      ),
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    line.product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                  ),
                ),
                Text(
                  formatDA(line.amount),
                  style: AmpereType.bodyStrong.copyWith(
                    color: colors.ink,
                    fontFeatures: AmpereType.tabular,
                  ),
                ),
                IconButton(
                  tooltip: 'Retirer',
                  onPressed: widget.onRemove,
                  icon: Icon(LucideIcons.x, size: 17, color: colors.ink3),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Prix d’achat / $unit',
                      suffixText: 'DA',
                      helperText: line.product.lastPurchasePriceHt == null
                          ? null
                          : 'Dernier prix : ${formatDA(line.product.lastPurchasePriceHt!)}',
                    ),
                    onChanged: (_) => _push(),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final d in PurchaseDestination.values)
                        ChoiceChip(
                          label: Text(d.label),
                          selected: line.destination == d,
                          onSelected: (_) => _push(destination: d),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: switch (line.destination) {
                      PurchaseDestination.both => [
                        qtyField('Au magasin', _store),
                        const SizedBox(width: 10),
                        qtyField('Au dépôt', _depot),
                      ],
                      PurchaseDestination.split => [
                        qtyField('Quantité totale (à répartir)', _qty),
                      ],
                      PurchaseDestination.store => [
                        qtyField('Quantité au magasin', _qty),
                      ],
                      PurchaseDestination.depot => [
                        qtyField('Quantité au dépôt', _qty),
                      ],
                    },
                  ),
                  if (line.destination == PurchaseDestination.split)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Posé au dépôt et marqué « à répartir » dans la page '
                        'Stock.',
                        style: AmpereType.meta.copyWith(color: colors.ink3),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
