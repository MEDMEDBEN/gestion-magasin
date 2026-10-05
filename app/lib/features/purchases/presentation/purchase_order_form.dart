import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
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
import '../../receptions/presentation/invoice_scan.dart';
import '../../suppliers/application/suppliers_controller.dart';
import '../application/purchases_controller.dart';
import '../../suppliers/data/suppliers_models.dart';
import '../data/purchases_models.dart';
import '../../../ui/widgets/search_picker.dart';

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
  late DateTime? _expectedDate = widget.existing?.expectedDate?.toLocal();
  late DateTime? _dueDate = widget.existing?.dueDate?.toLocal();
  bool _saving = false;
  String? _error;

  bool get _locked => widget.readOnly || _saving;

  /// Photo de facture → lignes PROPOSÉES (P2 n°24) : les produits reconnus
  /// s'ajoutent (ou mettent à jour leur ligne), une ligne vide est remplacée ;
  /// le bilan dit quoi vérifier. Rien n'est enregistré avant « Enregistrer ».
  Future<void> _fromInvoice() async {
    final scanned = await scanInvoice(context, ref);
    if (scanned == null || !mounted) return;
    final applied = [
      for (final l in scanned)
        if (l.productId != null) l,
    ];
    final ignored = [
      for (final l in scanned)
        if (l.productId == null) l,
    ];
    setState(() {
      _lines.removeWhere((l) {
        final empty = l.productId == null && l.quantity.text.isEmpty;
        if (empty) l.dispose();
        return empty;
      });
      // Un produit présent deux fois sur la facture : quantités ADDITIONNÉES.
      final seen = <String>{};
      for (final l in applied) {
        var fields = _lines
            .where((f) => f.productId == l.productId)
            .firstOrNull;
        if (fields == null) {
          if (_lines.length >= 200) {
            ignored.add(l);
            continue;
          }
          fields = _LineFields(productId: l.productId);
          _lines.add(fields);
        }
        if (l.quantity case final q?) {
          final before = parseQuantity(fields.quantity.text);
          fields.quantity.text = formatQuantity(
            seen.contains(l.productId) && before != null ? before + q : q,
          );
        }
        if (l.unitPriceHt case final p?) {
          fields.price.text = formatDA(p, withSymbol: false);
        }
        seen.add(l.productId!);
      }
      applied.removeWhere(ignored.contains);
      if (_lines.isEmpty) _lines.add(_LineFields());
    });
    await showScanSummary(context, applied: applied, ignored: ignored);
  }

  /// Date facultative : livraison prévue (retard fournisseur), échéance de
  /// paiement (dette fournisseur à payer).
  Widget _dateField(
    String label,
    DateTime? value,
    ValueChanged<DateTime?> onChanged,
  ) {
    final today = DateUtils.dateOnly(DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$label : ${value == null ? 'non précisée' : formatDate(value)}',
            ),
          ),
          TextButton(
            onPressed: _locked
                ? null
                : () async {
                    final initial = value ?? today;
                    final earliest = today.subtract(const Duration(days: 365));
                    final picked = await showDatePicker(
                      context: context,
                      helpText: label,
                      initialDate: initial,
                      // Une date plus ancienne reste affichable (sinon le
                      // sélecteur refuse de s'ouvrir).
                      firstDate: initial.isBefore(earliest)
                          ? initial
                          : earliest,
                      lastDate: today.add(const Duration(days: 730)),
                    );
                    if (picked != null) setState(() => onChanged(picked));
                  },
            child: Text(value == null ? 'Choisir' : 'Changer'),
          ),
          if (value != null && !_locked)
            IconButton(
              tooltip: 'Retirer la date',
              icon: const Icon(LucideIcons.x, size: 16),
              onPressed: () => setState(() => onChanged(null)),
            ),
        ],
      ),
    );
  }

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
            expectedDate: _expectedDate,
            dueDate: _dueDate,
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
        SearchPickerField<Supplier>(
          options: suppliers,
          idOf: (s) => s.id,
          labelOf: (s) => s.name,
          value: _supplierId,
          hint: 'Choisir un fournisseur',
          // Le fournisseur d'une commande existante ne change pas.
          onChanged: _locked || existing != null
              ? null
              : (v) => setState(() => _supplierId = v),
          validator: (v) => v == null ? 'Choisissez un fournisseur' : null,
        ),
        const SizedBox(height: 12),
        _dateField('Livraison prévue', _expectedDate, (d) => _expectedDate = d),
        _dateField('Échéance de paiement', _dueDate, (d) => _dueDate = d),
        const SizedBox(height: 8),
        for (var i = 0; i < _lines.length; i++) _lineRow(i, products, colors),
        if (!_locked)
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: _lines.length >= 200
                    ? null
                    : () => setState(() => _lines.add(_LineFields())),
                icon: const Icon(LucideIcons.plus, size: 16),
                label: const Text('Ajouter une ligne'),
              ),
              // P2 n°24 : lignes proposées depuis une photo de facture.
              TextButton.icon(
                onPressed: _fromInvoice,
                icon: const Icon(LucideIcons.scanText, size: 16),
                label: const Text('Remplir depuis une facture'),
              ),
            ],
          ),
        const Divider(height: 24),
        Text(
          'Total estimé : ${formatDA(_estimateHt)}'
          '${existing == null ? '' : ' · enregistré ${formatDA(existing.totalTtc)}'}',
          style: AmpereType.bodyStrong.copyWith(color: colors.ink),
        ),
        Text(
          'La dette fournisseur ne bouge qu’à la réception.',
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
          SearchPickerField<Product>(
            options: products,
            idOf: (p) => p.id,
            labelOf: (p) => '${p.name} · ${p.sku}',
            searchTextOf: (p) => '${p.name} ${p.sku} ${p.barcode}',
            value: line.productId,
            hint: 'Produit',
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
