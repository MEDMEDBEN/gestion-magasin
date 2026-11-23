import '../../../core/single_stock.dart';
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

/// Au-delà : le tableau ; en dessous (téléphone), des lignes sur deux rangs.
const _tableWidth = 760.0;

/// NOUVEL ACHAT (demandes MEDMEDBEN du 2026-11-19) : en haut, le fournisseur
/// et l'ajout des produits ; au milieu, le panier en TABLEAU — une colonne par
/// champ (prix d'achat, magasin, dépôt, à répartir) ; en bas, le total, le
/// paiement et la validation. Tout entre en stock d'un coup ; le non-payé
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
    final saved = await openFormPanel<Product>(
      context,
      ProductForm(
        canEdit: rights.canWriteProducts,
        canDisable: rights.canDisableProducts,
        canReadStock: rights.canReadStock,
        canReadSuppliers: rights.canReadSuppliers,
        canSetPrices: rights.canSetPrices,
        initialSupplierName: ref.read(purchaseCartProvider).supplierName,
        // Les quantités se saisissent sur la ligne du panier.
        forPurchase: true,
      ),
    );
    if (saved == null || !mounted) return;
    ref.read(purchaseCartProvider.notifier).add(saved);
  }

  int _paidAmount(int total) => !_canPay
      ? 0
      : switch (_paid) {
          _Paid.all => total,
          _Paid.none => 0,
          _Paid.part => parseDA(_partial.text) ?? -1,
        };

  Future<void> _submit(PurchaseCart cart) async {
    String? problem;
    if (cart.supplierId == null) {
      problem = 'Choisissez le fournisseur.';
    } else {
      for (final l in cart.lines) {
        if (l.total <= Quantity.zero) {
          problem = 'Quantité manquante : ${l.product.name}.';
          break;
        }
        if (l.unitPriceHt <= 0) {
          problem = 'Prix d’achat manquant : ${l.product.name}.';
          break;
        }
      }
    }
    final paid = _paidAmount(cart.total);
    if (problem == null && (paid < 0 || paid > cart.total)) {
      problem = 'Somme payée : entre 0 et ${formatDA(cart.total)}.';
    }
    if (problem != null) {
      setState(() => _error = problem);
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
    final wide = MediaQuery.sizeOf(context).width >= _tableWidth;

    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        title: Text(
          cart.supplierName == null || !wide
              ? 'Nouvel achat'
              : 'Nouvel achat — ${cart.supplierName}',
        ),
        actions: [
          if (!cart.isEmpty)
            TextButton.icon(
              onPressed: _saving ? null : notifier.clear,
              icon: const Icon(LucideIcons.trash2, size: 16),
              label: const Text('Vider'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AddBar(
            cart: cart,
            wide: wide,
            allProducts: _allProducts,
            onAllProducts: (v) => setState(() => _allProducts = v),
            onCreateSupplier: _saving ? null : _createSupplier,
            onCreateProduct: CatalogRights(widget.user).canWriteProducts
                ? (_saving ? null : _createProduct)
                : null,
          ),
          Expanded(
            child: cart.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.shoppingCart,
                          size: 32,
                          color: colors.ink3,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          cart.supplierId == null
                              ? 'Choisissez le fournisseur, puis ajoutez ses produits.'
                              : 'Ajoutez les produits achetés (barre du haut).',
                          textAlign: TextAlign.center,
                          style: AmpereType.body.copyWith(color: colors.ink3),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    children: [
                      Material(
                        color: colors.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(color: colors.line),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (wide) const _TableHeader(),
                            for (final (i, line) in cart.lines.indexed) ...[
                              if (i > 0 || wide)
                                Divider(height: 1, color: colors.lineSoft),
                              _LineRow(
                                key: ValueKey(line.product.id),
                                line: line,
                                wide: wide,
                                onChanged: (l) => notifier.update(i, l),
                                onRemove: () => notifier.remove(i),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (depotEnabled)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, left: 4),
                          child: Text(
                            '« À répartir » : posé au dépôt, à partager ensuite '
                            'entre magasin et dépôt (repère dans Stock).',
                            style: AmpereType.meta.copyWith(color: colors.ink3),
                          ),
                        ),
                    ],
                  ),
          ),
          _PayBar(
            cart: cart,
            wide: wide,
            canPay: _canPay,
            paid: _paid,
            partial: _partial,
            saving: _saving,
            error: _error,
            onPaid: (v) => setState(() => _paid = v),
            onPartialChanged: () => setState(() {}),
            onSubmit: () => _submit(cart),
          ),
        ],
      ),
    );
  }
}

// ── En haut : fournisseur + ajout des produits ──────────────────────────────

class _AddBar extends ConsumerWidget {
  const _AddBar({
    required this.cart,
    required this.wide,
    required this.allProducts,
    required this.onAllProducts,
    required this.onCreateSupplier,
    required this.onCreateProduct,
  });

  final PurchaseCart cart;
  final bool wide;
  final bool allProducts;
  final ValueChanged<bool> onAllProducts;
  final VoidCallback? onCreateSupplier;

  /// `null` : pas le droit de créer un produit.
  final VoidCallback? onCreateProduct;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final notifier = ref.read(purchaseCartProvider.notifier);
    final suppliers =
        ref.watch(supplierSearchProvider('')).value ?? const <Supplier>[];
    final products =
        ref.watch(activeProductsProvider).value ?? const <Product>[];
    final supplierName = cart.supplierName?.trim().toLowerCase();
    // Ses produits d'abord : ceux dont il est le fournisseur principal.
    final offered = [
      for (final p in products)
        if (allProducts ||
            supplierName == null ||
            p.mainSupplierName?.trim().toLowerCase() == supplierName)
          p,
    ];
    const dense = InputDecoration(isDense: true);

    final supplier = Autocomplete<Supplier>(
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
      fieldViewBuilder: (context, controller, focus, _) => TextField(
        controller: controller,
        focusNode: focus,
        decoration: dense.copyWith(
          prefixIcon: const Icon(LucideIcons.truck, size: 17),
          hintText: 'Fournisseur',
        ),
      ),
    );

    final product = Autocomplete<Product>(
      key: ValueKey('produit-${cart.lines.length}-$allProducts'),
      displayStringForOption: (p) => p.name,
      optionsBuilder: (v) {
        final q = v.text.trim().toLowerCase();
        final inCart = {for (final l in cart.lines) l.product.id};
        return offered
            .where(
              (p) =>
                  !inCart.contains(p.id) &&
                  (q.isEmpty ||
                      p.name.toLowerCase().contains(q) ||
                      p.sku.toLowerCase().contains(q) ||
                      p.barcode == q),
            )
            .take(12);
      },
      onSelected: notifier.add,
      fieldViewBuilder: (context, controller, focus, _) => TextField(
        controller: controller,
        focusNode: focus,
        decoration: dense.copyWith(
          prefixIcon: const Icon(LucideIcons.search, size: 17),
          hintText: cart.supplierId == null || allProducts
              ? 'Ajouter un produit (nom, référence, code-barres)'
              : 'Ajouter un produit de ${cart.supplierName}',
        ),
      ),
    );

    final supplierTools = IconButton.outlined(
      tooltip: 'Nouveau fournisseur',
      onPressed: onCreateSupplier,
      icon: const Icon(LucideIcons.userPlus, size: 17),
    );
    final productTools = [
      if (cart.supplierId != null)
        FilterChip(
          label: const Text('Tous'),
          tooltip:
              'Montrer tous les produits, pas seulement ceux du fournisseur',
          selected: allProducts,
          onSelected: onAllProducts,
        ),
      if (onCreateProduct != null)
        IconButton.outlined(
          tooltip: 'Nouveau produit',
          onPressed: onCreateProduct,
          icon: const Icon(LucideIcons.packagePlus, size: 17),
        ),
    ];

    return Material(
      color: colors.surface,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.line)),
        ),
        child: wide
            ? Row(
                children: [
                  SizedBox(width: 280, child: supplier),
                  const SizedBox(width: 6),
                  supplierTools,
                  const SizedBox(width: 16),
                  Expanded(child: product),
                  for (final t in productTools) ...[
                    const SizedBox(width: 6),
                    t,
                  ],
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: supplier),
                      const SizedBox(width: 6),
                      supplierTools,
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: product),
                      for (final t in productTools) ...[
                        const SizedBox(width: 6),
                        t,
                      ],
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

// ── Le panier en tableau ────────────────────────────────────────────────────

/// Largeurs des colonnes chiffrées (poste).
class _Col {
  static const price = 120.0;
  static const qty = 104.0;
  static const amount = 120.0;
  static const remove = 40.0;
}

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    Widget head(String text, double? width, {bool end = true}) {
      final t = Text(
        text.toUpperCase(),
        textAlign: end ? TextAlign.end : TextAlign.start,
        style: AmpereType.label.copyWith(color: colors.ink3),
      );
      return width == null
          ? Expanded(child: t)
          : SizedBox(width: width, child: t);
    }

    return Container(
      color: colors.surface2,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          head('Produit', null, end: false),
          head('Prix d’achat', _Col.price),
          const SizedBox(width: 8),
          head(depotEnabled ? 'Magasin' : 'Quantité', _Col.qty),
          const SizedBox(width: 8),
          if (depotEnabled) ...[
            head('Dépôt', _Col.qty),
            const SizedBox(width: 8),
            head('À répartir', _Col.qty),
            const SizedBox(width: 8),
          ],
          head('Montant', _Col.amount),
          const SizedBox(width: _Col.remove),
        ],
      ),
    );
  }
}

class _LineRow extends StatefulWidget {
  const _LineRow({
    super.key,
    required this.line,
    required this.wide,
    required this.onChanged,
    required this.onRemove,
  });

  final PurchaseCartLine line;
  final bool wide;
  final ValueChanged<PurchaseCartLine> onChanged;
  final VoidCallback onRemove;

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  static String _show(Quantity q) =>
      q == Quantity.zero ? '' : formatQuantity(q);

  late final _price = TextEditingController(
    text: widget.line.unitPriceHt == 0
        ? ''
        : formatDA(widget.line.unitPriceHt, withSymbol: false),
  );
  late final _store = TextEditingController(text: _show(widget.line.store));
  late final _depot = TextEditingController(text: _show(widget.line.depot));
  late final _split = TextEditingController(text: _show(widget.line.split));

  @override
  void dispose() {
    for (final c in [_price, _store, _depot, _split]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Saisie → ligne. Une saisie négative ou invalide compte pour 0 (et le
  /// champ le signale) — jamais de valeur négative (2026-11-19).
  void _push() {
    Quantity q(TextEditingController c) =>
        parseQuantity(c.text) ?? Quantity.zero;
    widget.onChanged(
      widget.line.copyWith(
        unitPriceHt: parseDA(_price.text) ?? 0,
        store: q(_store),
        depot: q(_depot),
        split: q(_split),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final line = widget.line;
    final unit = line.product.unit.short;

    Widget field(
      TextEditingController c, {
      String? label,
      String? suffix,
      bool money = false,
    }) => TextFormField(
      controller: c,
      textAlign: TextAlign.end,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (v) {
        final raw = v?.trim() ?? '';
        if (raw.isEmpty) return null;
        final ok = money ? parseDA(raw) != null : parseQuantity(raw) != null;
        return ok ? null : 'Invalide';
      },
      style: AmpereType.bodyStrong.copyWith(fontFeatures: AmpereType.tabular),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        suffixText: suffix,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      ),
      onChanged: (_) => _push(),
    );

    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          line.product.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AmpereType.bodyStrong.copyWith(color: colors.ink),
        ),
        Text(
          [
            line.product.sku,
            if (line.product.lastPurchasePriceHt case final last?)
              'dernier achat ${formatDA(last)}',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
      ],
    );
    final amount = Text(
      formatDA(line.amount),
      textAlign: TextAlign.end,
      style: AmpereType.bodyStrong.copyWith(
        color: colors.ink,
        fontFeatures: AmpereType.tabular,
      ),
    );
    final remove = IconButton(
      tooltip: 'Retirer',
      visualDensity: VisualDensity.compact,
      onPressed: widget.onRemove,
      icon: Icon(LucideIcons.x, size: 16, color: colors.ink3),
    );

    if (widget.wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 0, 6),
        child: Row(
          children: [
            Expanded(child: name),
            SizedBox(
              width: _Col.price,
              child: field(_price, suffix: 'DA', money: true),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: _Col.qty,
              child: field(_store, suffix: unit),
            ),
            const SizedBox(width: 8),
            if (depotEnabled) ...[
              SizedBox(
                width: _Col.qty,
                child: field(_depot, suffix: unit),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: _Col.qty,
                child: field(_split, suffix: unit),
              ),
              const SizedBox(width: 8),
            ],
            SizedBox(width: _Col.amount, child: amount),
            SizedBox(width: _Col.remove, child: remove),
          ],
        ),
      );
    }
    // Téléphone : deux rangs — nom et montant, puis les quatre champs.
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 0, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: name),
              amount,
              remove,
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: field(_price, label: 'Prix', money: true),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 4,
                  child: field(
                    _store,
                    label: depotEnabled ? 'Magasin' : 'Quantité',
                  ),
                ),
                if (depotEnabled) ...[
                  const SizedBox(width: 6),
                  Expanded(flex: 4, child: field(_depot, label: 'Dépôt')),
                  const SizedBox(width: 6),
                  Expanded(flex: 4, child: field(_split, label: 'Répartir')),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── En bas : total, paiement, validation ────────────────────────────────────

class _PayBar extends StatelessWidget {
  const _PayBar({
    required this.cart,
    required this.wide,
    required this.canPay,
    required this.paid,
    required this.partial,
    required this.saving,
    required this.error,
    required this.onPaid,
    required this.onPartialChanged,
    required this.onSubmit,
  });

  final PurchaseCart cart;
  final bool wide;
  final bool canPay;
  final _Paid paid;
  final TextEditingController partial;
  final bool saving;
  final String? error;
  final ValueChanged<_Paid> onPaid;
  final VoidCallback onPartialChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final given = switch (paid) {
      _Paid.all => cart.total,
      _Paid.none => 0,
      _Paid.part => parseDA(partial.text) ?? 0,
    };
    final rest = canPay
        ? (cart.total - given).clamp(0, cart.total)
        : cart.total;

    final total = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'TOTAL · ${cart.lines.length} produit(s)',
          style: AmpereType.label.copyWith(color: colors.ink3),
        ),
        Text(
          formatDA(cart.total),
          style: AmpereType.h3.copyWith(
            color: colors.ink,
            fontFeatures: AmpereType.tabular,
          ),
        ),
      ],
    );
    final payment = canPay
        ? Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<_Paid>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: _Paid.all, label: Text('Payé')),
                  ButtonSegment(value: _Paid.part, label: Text('En partie')),
                  ButtonSegment(value: _Paid.none, label: Text('Pas payé')),
                ],
                selected: {paid},
                onSelectionChanged: (s) => onPaid(s.first),
              ),
              if (paid == _Paid.part)
                SizedBox(
                  width: 150,
                  child: TextField(
                    controller: partial,
                    autofocus: true,
                    textAlign: TextAlign.end,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Somme donnée',
                      suffixText: 'DA',
                    ),
                    onChanged: (_) => onPartialChanged(),
                  ),
                ),
            ],
          )
        : null;
    final debt = Text(
      cart.isEmpty
          ? ''
          : rest == 0
          ? 'Aucune dette'
          : 'Dette : ${formatDA(rest)}',
      style: AmpereType.bodyStrong.copyWith(
        color: rest == 0 ? colors.ok : colors.warn,
      ),
    );
    final submit = FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
      onPressed: saving || cart.isEmpty ? null : onSubmit,
      icon: const Icon(LucideIcons.packageCheck, size: 18),
      label: Text(saving ? 'Enregistrement…' : 'Valider l’achat'),
    );

    return Material(
      color: colors.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.line)),
        ),
        padding: EdgeInsets.fromLTRB(
          16,
          10,
          16,
          10 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  error!,
                  style: AmpereType.body.copyWith(color: colors.error),
                ),
              ),
            if (wide)
              Row(
                children: [
                  total,
                  const SizedBox(width: 24),
                  if (payment != null) Flexible(child: payment),
                  const Spacer(),
                  debt,
                  const SizedBox(width: 16),
                  submit,
                ],
              )
            else ...[
              Row(
                children: [
                  Expanded(child: total),
                  debt,
                ],
              ),
              if (payment != null) ...[const SizedBox(height: 8), payment],
              const SizedBox(height: 8),
              submit,
            ],
          ],
        ),
      ),
    );
  }
}
