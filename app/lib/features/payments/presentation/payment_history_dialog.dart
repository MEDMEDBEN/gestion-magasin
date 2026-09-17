import 'package:flutter/material.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/screen_state.dart';
import '../data/payment_models.dart';

/// Historique des paiements d'un client ou d'un fournisseur (un seul écran
/// pour les deux). `onReverse` non nul (ADMIN) : chaque paiement encore actif
/// peut être CONTRE-PASSÉ — écriture opposée, jamais suppression.
Future<void> showPaymentHistory(
  BuildContext context, {
  required String title,
  required Future<List<PaymentHistoryItem>> Function() load,
  Future<void> Function(PaymentHistoryItem payment, String reason)? onReverse,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _PaymentHistoryDialog(title: title, load: load, onReverse: onReverse),
  );
}

class _PaymentHistoryDialog extends StatefulWidget {
  const _PaymentHistoryDialog({
    required this.title,
    required this.load,
    this.onReverse,
  });

  final String title;
  final Future<List<PaymentHistoryItem>> Function() load;
  final Future<void> Function(PaymentHistoryItem, String)? onReverse;

  @override
  State<_PaymentHistoryDialog> createState() => _PaymentHistoryDialogState();
}

class _PaymentHistoryDialogState extends State<_PaymentHistoryDialog> {
  late Future<List<PaymentHistoryItem>> _items = widget.load();
  String? _error;

  Future<void> _reverse(PaymentHistoryItem payment) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => _ReverseDialog(payment: payment),
    );
    if (reason == null || !mounted) return;
    try {
      await widget.onReverse!(payment, reason);
      if (!mounted) return;
      setState(() {
        _error = null;
        _items = widget.load();
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.userMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: FutureBuilder<List<PaymentHistoryItem>>(
          future: _items,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              final error = snapshot.error;
              return AmpereInlineAlert(
                message: error is ApiException ? error.userMessage : '$error',
              );
            }
            final items = snapshot.data!;
            if (items.isEmpty) {
              return const Text('Aucun paiement enregistré.');
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[
                  AmpereInlineAlert(message: _error!),
                  const SizedBox(height: 8),
                ],
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in items)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            formatDA(p.amount),
                            style: TextStyle(
                              color: p.amount < 0 ? colors.error : null,
                              decoration: p.reversedById != null
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          subtitle: Text(
                            [
                              formatDateTime(p.paidAt),
                              p.fromCash ? 'caisse' : 'hors caisse',
                              if (p.reversesPaymentId != null)
                                'contre-passation',
                              if (p.reversedById != null) 'annulé',
                              if (p.note != null) p.note!,
                            ].join(' · '),
                          ),
                          trailing: widget.onReverse != null && p.canBeReversed
                              ? TextButton(
                                  onPressed: () => _reverse(p),
                                  child: const Text('Contre-passer'),
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}

class _ReverseDialog extends StatefulWidget {
  const _ReverseDialog({required this.payment});

  final PaymentHistoryItem payment;

  @override
  State<_ReverseDialog> createState() => _ReverseDialogState();
}

class _ReverseDialogState extends State<_ReverseDialog> {
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _reason.text.trim();
    if (reason.length < 3) {
      setState(() => _error = 'Indiquez le motif (3 caractères minimum)');
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return AlertDialog(
      title: Text('Contre-passer ${formatDA(widget.payment.amount)} ?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.payment.fromCash
                ? 'Une écriture opposée est ajoutée et les espèces passent par '
                      'votre caisse ouverte. Le paiement d’origine reste dans '
                      'l’historique.'
                : 'Une écriture opposée est ajoutée ; la caisse n’est pas '
                      'touchée. Le paiement d’origine reste dans l’historique.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            autofocus: true,
            maxLength: 500,
            decoration: InputDecoration(labelText: 'Motif', errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Garder'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: colors.error),
          onPressed: _submit,
          child: const Text('Contre-passer'),
        ),
      ],
    );
  }
}
