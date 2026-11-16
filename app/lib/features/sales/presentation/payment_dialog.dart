import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/money.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';

/// Billets algériens courants (centimes) : les montants qu'on tend au comptoir.
const _bills = [20000, 50000, 100000, 200000];

/// Montants proposés en un geste : le compte juste, puis les arrondis
/// supérieurs qu'un client tend vraiment (billet, multiple de 100/500/1 000).
List<int> quickAmounts(int total) {
  int up(int step) => ((total + step - 1) ~/ step) * step;
  final amounts = <int>{
    total,
    up(10000),
    up(50000),
    up(100000),
    up(500000),
    for (final bill in _bills)
      if (bill > total) bill,
  }.where((a) => a >= total).toList()..sort();
  return amounts.take(5).toList();
}

/// Encaissement façon caisse : total, espèces reçues (saisie ou billets en
/// un geste), monnaie à rendre en direct — ou reste à crédit si un client est
/// choisi. Une vente comptoir doit être soldée : le bouton reste grisé.
/// Rend les espèces REÇUES (centimes), `null` si annulé.
Future<int?> showPaymentDialog(
  BuildContext context, {
  required int total,
  String? customerName,
}) => showDialog<int>(
  context: context,
  builder: (_) => _PaymentDialog(total: total, customerName: customerName),
);

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.total, this.customerName});

  final int total;
  final String? customerName;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  late final _received = TextEditingController(
    text: formatDA(widget.total, withSymbol: false),
  );

  @override
  void dispose() {
    _received.dispose();
    super.dispose();
  }

  int? get _amount => parseDA(_received.text);

  void _set(int amount) =>
      setState(() => _received.text = formatDA(amount, withSymbol: false));

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final amount = _amount;
    final total = widget.total;
    final credit = widget.customerName != null;
    // État du paiement, en couleur : vert rendu, orange crédit, rouge refusé.
    final (
      Color tone,
      IconData icon,
      String message,
      bool valid,
    ) = switch (amount) {
      null ||
      < 0 => (colors.error, LucideIcons.circleAlert, 'Montant invalide', false),
      final a when a >= total => (
        colors.ok,
        LucideIcons.handCoins,
        a == total
            ? 'Compte juste'
            : 'Monnaie à rendre : ${formatDA(a - total)}',
        true,
      ),
      final a when credit => (
        colors.warn,
        LucideIcons.notebookPen,
        'Reste à crédit de ${widget.customerName} : ${formatDA(total - a)}',
        true,
      ),
      final a => (
        colors.error,
        LucideIcons.circleAlert,
        'Il manque ${formatDA(total - a)} — une vente comptoir doit être '
            'soldée (ou choisissez le client pour un crédit)',
        false,
      ),
    };
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Encaisser ${formatDA(total)}',
                style: AmpereType.sectionTitle.copyWith(color: colors.ink),
              ),
              const SizedBox(height: 12),
              // Afficheur : le total à payer.
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [colors.bgAlt, colors.bg],
                  ),
                  border: Border.all(
                    color: colors.accent.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      'À PAYER',
                      style: AmpereType.label.copyWith(
                        color: colors.ink3,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FittedBox(
                        alignment: Alignment.centerRight,
                        fit: BoxFit.scaleDown,
                        child: Text(
                          formatDA(total),
                          style: AmpereType.numericHero.copyWith(
                            fontSize: 32,
                            color: colors.accentHi,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _received,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: AmpereType.input.copyWith(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
                decoration: const InputDecoration(
                  labelText: 'Espèces reçues',
                  suffixText: 'DA',
                  prefixIcon: Icon(LucideIcons.banknote, size: 20),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (valid) Navigator.of(context).pop(_amount);
                },
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final quick in quickAmounts(total))
                    ActionChip(
                      avatar: Icon(
                        quick == total
                            ? LucideIcons.check
                            : LucideIcons.banknote,
                        size: 16,
                      ),
                      label: Text(
                        quick == total ? 'Compte juste' : formatDA(quick),
                      ),
                      onPressed: () => _set(quick),
                    ),
                  if (credit)
                    ActionChip(
                      avatar: const Icon(LucideIcons.notebookPen, size: 16),
                      label: const Text('Tout à crédit'),
                      onPressed: () => _set(0),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: tone.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    Icon(icon, color: tone, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        message,
                        style: AmpereType.bodyStrong.copyWith(color: tone),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Annuler'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.ok,
                        foregroundColor: colors.bg,
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: valid
                          ? () => Navigator.of(context).pop(_amount)
                          : null,
                      icon: const Icon(LucideIcons.check, size: 18),
                      label: const Text('Valider la vente'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
