import 'package:flutter/material.dart';

import '../../../core/dates.dart';
import '../../../core/money.dart';
import '../../../ui/widgets/fields_dialog.dart';

/// Chèque saisi : montant (centimes), n°, banque, échéance `AAAA-MM-JJ`.
typedef ChequeEntry = ({
  int amount,
  String number,
  String bank,
  String? dueDate,
});

/// Saisie d'un chèque (P1 bis n°21n), partagée par le règlement client et le
/// paiement fournisseur : montant, n°, banque, puis l'échéance au sélecteur de
/// date (« Annuler » : sans échéance). Rend `null` si abandonné ; un champ
/// invalide est signalé par `onInvalid` (le serveur revérifie tout).
Future<ChequeEntry?> askCheque(
  BuildContext context, {
  required String title,
  required int initialAmount,
  required String confirm,
  required void Function(String message) onInvalid,
}) async {
  final fields = await askFields(
    context,
    title: title,
    confirm: confirm,
    fields: [
      (
        key: 'amount',
        label: 'Montant (DA)',
        initial: formatDA(initialAmount, withSymbol: false),
      ),
      (key: 'number', label: 'N° du chèque', initial: ''),
      (key: 'bank', label: 'Banque', initial: ''),
    ],
  );
  if (fields == null) return null;
  final amount = parseDA(fields['amount']!);
  if (amount == null || amount <= 0) {
    onInvalid('Montant invalide');
    return null;
  }
  if (fields['number']!.isEmpty || fields['bank']!.isEmpty) {
    onInvalid('Le n° du chèque et la banque sont obligatoires');
    return null;
  }
  if (!context.mounted) return null;
  final today = DateUtils.dateOnly(DateTime.now());
  final due = await showDatePicker(
    context: context,
    helpText: 'Échéance du chèque (Annuler : aucune)',
    initialDate: today,
    firstDate: today.subtract(const Duration(days: 365)),
    lastDate: today.add(const Duration(days: 730)),
  );
  return (
    amount: amount,
    number: fields['number']!,
    bank: fields['bank']!,
    dueDate: due == null ? null : isoDay(due),
  );
}
