import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';

/// Remise saisie en DA ou en POURCENTAGE (décision MEDMEDBEN du 2026-10-12),
/// sur un montant `baseHt` (centimes). Le pourcentage est converti en centimes
/// ici, arrondi au centime ; le serveur ne reçoit qu'un montant. Au-delà de
/// `maxHt` (vente sous le prix d'achat), « Appliquer » reste grisé.
/// Rend la remise en centimes (0 : retirée), `null` si annulé.
Future<int?> askDiscount(
  BuildContext context, {
  required String title,
  required int baseHt,
  required int maxHt,
  int initialHt = 0,
}) => showDialog<int>(
  context: context,
  builder: (_) => _DiscountDialog(
    title: title,
    baseHt: baseHt,
    maxHt: maxHt,
    initialHt: initialHt,
  ),
);

/// Pourcentage (« 7,5 ») → remise en centimes sur `baseHt`, arrondie.
int? percentOf(int baseHt, String raw) {
  final text = raw.trim().replaceAll(',', '.');
  final percent = Decimal.tryParse(text);
  if (percent == null || percent < Decimal.zero) return null;
  if (percent > Decimal.fromInt(100)) return null;
  return (Decimal.fromInt(baseHt) * percent / Decimal.fromInt(100))
      .toDecimal(scaleOnInfinitePrecision: 4)
      .round()
      .toBigInt()
      .toInt();
}

class _DiscountDialog extends StatefulWidget {
  const _DiscountDialog({
    required this.title,
    required this.baseHt,
    required this.maxHt,
    required this.initialHt,
  });

  final String title;
  final int baseHt;
  final int maxHt;
  final int initialHt;

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  bool _percent = false;
  late final _field = TextEditingController(
    text: widget.initialHt > 0
        ? formatDA(widget.initialHt, withSymbol: false)
        : '',
  );

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  int? get _amount {
    if (_field.text.trim().isEmpty) return 0;
    return _percent
        ? percentOf(widget.baseHt, _field.text)
        : parseDA(_field.text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final amount = _amount;
    final valid = amount != null && amount >= 0 && amount <= widget.maxHt;
    final message = amount == null
        ? 'Saisie invalide'
        : amount > widget.maxHt
        ? 'Trop forte : ${formatDA(widget.maxHt)} au plus (prix d’achat)'
        : 'Remise ${formatDA(amount)} → net ${formatDA(widget.baseHt - amount)}';
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Montant (DA)')),
                ButtonSegment(value: true, label: Text('Pourcentage (%)')),
              ],
              selected: {_percent},
              onSelectionChanged: (s) => setState(() {
                _percent = s.first;
                _field.clear();
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _field,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: _percent ? 'Remise en %' : 'Remise en DA',
                suffixText: _percent ? '%' : 'DA',
                helperText: 'Sur ${formatDA(widget.baseHt)} · 0 : retirer',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              style: AmpereType.bodyStrong.copyWith(
                color: valid ? colors.ok : colors.error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          // Relu AU CLIC : le dernier caractère tapé compte, même si l'écran
          // n'a pas encore été redessiné.
          onPressed: valid
              ? () {
                  final now = _amount;
                  if (now != null && now >= 0 && now <= widget.maxHt) {
                    Navigator.of(context).pop(now);
                  }
                }
              : null,
          child: const Text('Appliquer'),
        ),
      ],
    );
  }
}
