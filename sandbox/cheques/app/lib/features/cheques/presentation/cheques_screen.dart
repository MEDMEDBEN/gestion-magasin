import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/fields_dialog.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/cheques_controller.dart';
import '../data/cheques_api.dart';

/// Portefeuille de chèques (ADMIN, P1 bis n°21n) : chèques reçus des clients
/// et émis aux fournisseurs. Un chèque en portefeuille se déclare encaissé
/// (rien ne bouge) ou rejeté (la dette revient, alerte). Aucune caisse n'est
/// jamais touchée.
class ChequesScreen extends ConsumerWidget {
  const ChequesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final filter = ref.watch(chequeFilterProvider);
    final cheques = ref.watch(chequesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
          child: Row(
            children: [
              for (final choice in const <ChequeStatus?>[
                ChequeStatus.inWallet,
                ChequeStatus.cashed,
                ChequeStatus.rejected,
                null,
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(choice?.label ?? 'Tous'),
                    selected: filter == choice,
                    onSelected: (_) =>
                        ref.read(chequeFilterProvider.notifier).set(choice),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: cheques.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException
                  ? error.userMessage
                  : 'Les chèques n’ont pas pu être chargés.',
              onRetry: () => ref.invalidate(chequesProvider),
            ),
            data: (items) => items.isEmpty
                ? const ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Aucun chèque',
                    message:
                        'Les chèques s’enregistrent depuis la fiche du client '
                        '(« Encaisser un chèque ») ou du fournisseur '
                        '(« Payer par chèque »).',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final c in items)
                        Card(
                          key: ValueKey(c.id),
                          child: ListTile(
                            title: Text(
                              '${c.isCustomer ? 'Reçu de' : 'Émis à'} '
                              '${c.partyName} · ${formatDA(c.amount)}',
                            ),
                            subtitle: Text(
                              [
                                'n° ${c.number}',
                                c.bank,
                                'remis le ${formatDate(c.paidAt.toLocal())}',
                                if (c.dueDate != null)
                                  'échéance ${formatIsoDay(c.dueDate!)}',
                              ].join(' · '),
                            ),
                            trailing: AmpereBadge(
                              label: c.status.label,
                              tone: switch (c.status) {
                                ChequeStatus.inWallet => StatusTone.info,
                                ChequeStatus.cashed => StatusTone.ok,
                                ChequeStatus.rejected => StatusTone.error,
                              },
                            ),
                            onTap: c.status == ChequeStatus.inWallet
                                ? () => _decide(context, ref, c)
                                : null,
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _decide(BuildContext context, WidgetRef ref, Cheque c) async {
    final choice = await showDialog<ChequeStatus>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Chèque n° ${c.number} — ${formatDA(c.amount)}'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(ChequeStatus.cashed),
            child: Text(
              c.isCustomer ? 'Encaissé par la banque' : 'Débité par la banque',
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(ChequeStatus.rejected),
            child: const Text('Rejeté par la banque (la dette revient)'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    String? reason;
    if (choice == ChequeStatus.rejected) {
      final fields = await askFields(
        context,
        title: 'Rejet du chèque n° ${c.number}',
        confirm: 'Déclarer rejeté',
        fields: const [
          (key: 'reason', label: 'Motif (facultatif)', initial: ''),
        ],
      );
      if (fields == null || !context.mounted) return;
      reason = fields['reason']!.isEmpty ? null : fields['reason'];
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      final done = await ref
          .read(chequesActionsProvider)
          .decide(c, choice, reason: reason);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            done.status == ChequeStatus.rejected
                ? 'Chèque rejeté : ${formatDA(c.amount)} remis sur la dette '
                      'de ${c.partyName}.'
                : 'Chèque n° ${c.number} : ${done.status.label.toLowerCase()}.',
          ),
        ),
      );
    } on ApiException catch (error) {
      if (error.statusCode == 409) ref.invalidate(chequesProvider);
      messenger.showSnackBar(SnackBar(content: Text(error.userMessage)));
    }
  }
}
