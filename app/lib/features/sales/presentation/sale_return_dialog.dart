import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/quantity.dart';
import '../../catalog/application/catalog_controller.dart';
import '../application/sales_controller.dart';
import '../data/sales_models.dart';

/// Retour d'articles d'une vente (ADMIN, P1 bis n°21l) : quantité rendue par
/// ligne (au plus ce qui n'est pas déjà revenu), remboursement en espèces ou
/// déduction de la dette, motif. Le serveur vérifie tout et fixe les montants.
/// Rend le retour enregistré, ou `null`.
Future<SaleReturn?> showSaleReturnDialog(
  BuildContext context, {
  required Sale sale,
  required List<SaleReturn> previous,
}) => showDialog<SaleReturn>(
  context: context,
  builder: (context) => _SaleReturnDialog(sale: sale, previous: previous),
);

class _SaleReturnDialog extends ConsumerStatefulWidget {
  const _SaleReturnDialog({required this.sale, required this.previous});

  final Sale sale;
  final List<SaleReturn> previous;

  @override
  ConsumerState<_SaleReturnDialog> createState() => _SaleReturnDialogState();
}

class _SaleReturnDialogState extends ConsumerState<_SaleReturnDialog> {
  late final Map<String, TextEditingController> _quantities = {
    for (final l in widget.sale.lines) l.id: TextEditingController(),
  };
  final _reason = TextEditingController();
  // Espèces par défaut si le client a payé ; sinon, déduction de la dette.
  late String _method = widget.sale.remainingAmount > 0 ? 'DETTE' : 'ESPECES';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [..._quantities.values, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Quantité encore rendable d'une ligne.
  Quantity _left(SaleLine line) {
    var back = Quantity.zero;
    for (final r in widget.previous) {
      for (final l in r.lines) {
        if (l.saleLineId == line.id) back = back + l.quantity;
      }
    }
    return line.quantity - back;
  }

  Future<void> _submit() async {
    final asked = <String, Quantity>{};
    for (final line in widget.sale.lines) {
      final raw = _quantities[line.id]!.text.trim();
      if (raw.isEmpty) continue;
      final q = parseQuantity(raw);
      if (q == null || q <= Quantity.zero || q > _left(line)) {
        setState(() => _error = 'Quantité invalide sur une ligne');
        return;
      }
      asked[line.id] = q;
    }
    if (asked.isEmpty) {
      setState(() => _error = 'Indiquez au moins une quantité rendue');
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
          .read(salesActionsProvider)
          .returnItems(
            widget.sale.id,
            quantities: asked,
            refundMethod: _method,
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
    final products = {
      for (final p
          in ref.watch(activeProductsProvider).value ?? const <Never>[])
        p.id: p,
    };
    final credit = widget.sale.customerId != null;
    return AlertDialog(
      title: Text(
        'Retour sur ${widget.sale.invoiceNumber ?? widget.sale.number}',
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final line in widget.sale.lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${products[line.productId]?.name ?? 'Produit'} — '
                          'vendu ${formatQuantity(line.quantity)}, '
                          'rendable ${formatQuantity(_left(line))}',
                        ),
                      ),
                      SizedBox(
                        width: 90,
                        child: TextField(
                          controller: _quantities[line.id],
                          enabled: !_saving && _left(line) > Quantity.zero,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(hintText: '0'),
                        ),
                      ),
                    ],
                  ),
                ),
              const Divider(),
              RadioGroup<String>(
                groupValue: _method,
                onChanged: (v) {
                  if (!_saving && v != null) setState(() => _method = v);
                },
                child: Column(
                  children: [
                    const RadioListTile(
                      value: 'ESPECES',
                      title: Text('Rembourser en espèces (ma caisse)'),
                    ),
                    if (credit)
                      RadioListTile(
                        value: 'DETTE',
                        title: Text(
                          'Déduire de la dette du client '
                          '(reste dû ${formatDA(widget.sale.remainingAmount)})',
                        ),
                      ),
                  ],
                ),
              ),
              TextField(
                controller: _reason,
                enabled: !_saving,
                maxLength: 300,
                decoration: const InputDecoration(labelText: 'Motif'),
              ),
              if (widget.sale.invoiceNumber != null)
                const Text(
                  'Vente facturée : une facture d’avoir numérotée sera émise.',
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
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
