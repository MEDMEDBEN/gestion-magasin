import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/navigation.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/amount_dialog.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../sales/application/sales_controller.dart';
import '../application/quotes_controller.dart';
import '../data/quote_models.dart';
import '../../../ui/widgets/period_filter.dart';

/// Devis (spec §8quater). On les FAIT depuis le panier de l'écran Vente — même
/// recherche, même douchette, mêmes prix. Ici : les retrouver, les imprimer,
/// suivre leur réponse et convertir en vente ceux que le client a acceptés.
class QuotesScreen extends ConsumerWidget {
  const QuotesScreen({super.key, required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final filter = ref.watch(quoteFilterProvider);
    final quotes = ref.watch(quotesProvider);
    // Gardé vivant et chargé : la conversion encaisse dans CETTE caisse.
    ref.watch(currentCashSessionProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
          child: Wrap(
            spacing: 0,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PeriodFilter(
                value: ref.watch(quotePeriodProvider),
                onChanged: ref.read(quotePeriodProvider.notifier).set,
              ),
              const SizedBox(width: 12),
              for (final choice in const <QuoteStatus?>[
                null,
                QuoteStatus.draft,
                QuoteStatus.sent,
                QuoteStatus.accepted,
                QuoteStatus.converted,
                QuoteStatus.refused,
                QuoteStatus.expired,
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(choice?.label ?? 'Tous'),
                    selected: filter == choice,
                    onSelected: (_) =>
                        ref.read(quoteFilterProvider.notifier).set(choice),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: quotes.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException
                  ? error.userMessage
                  : 'Les devis n’ont pas pu être chargés.',
              onRetry: () => ref.invalidate(quotesProvider),
            ),
            data: (items) => items.isEmpty
                ? const ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Aucun devis',
                    message:
                        'Composez le panier dans « Vente », puis « Faire un '
                        'devis » : rien ne sort du stock.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final quote in items)
                        Card(
                          key: ValueKey(quote.id),
                          child: ListTile(
                            title: Text(
                              '${quote.number} · '
                              '${quote.customerName ?? 'Client comptoir'}',
                            ),
                            subtitle: Text(
                              '${quote.lines.length} ligne(s) · '
                              '${formatDA(quote.totalTtc)} TTC'
                              '${quote.validUntil == null ? '' : ' · valable jusqu’au ${_day(quote.validUntil!)}'}',
                            ),
                            trailing: AmpereBadge(
                              label: quote.status.label,
                              tone: _tone(quote.status),
                            ),
                            onTap: () => _openActions(context, ref, quote),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _openActions(
    BuildContext context,
    WidgetRef ref,
    Quote quote,
  ) async {
    final status = quote.status;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${quote.number} — ${status.label}'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('print'),
            child: const Text('Imprimer / partager le PDF'),
          ),
          // Miroir du serveur : son auteur, ou l'admin.
          if (status.canEdit &&
              (quote.userId == user.id || user.hasRole('ADMIN')))
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('edit'),
              child: const Text('Modifier (dans le panier de la vente)'),
            ),
          if (status.canSend)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('send'),
              child: const Text('Marquer comme envoyé au client'),
            ),
          if (status.canAccept)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('accept'),
              child: const Text('Le client accepte'),
            ),
          if (status.canConvert)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('convert'),
              child: Text('Convertir en vente (${formatDA(quote.totalTtc)})'),
            ),
          if (status.canRefuse)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('refuse'),
              child: const Text('Le client refuse'),
            ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;
    final actions = ref.read(quoteActionsProvider);
    try {
      switch (action) {
        case 'print':
          await actions.print(quote);
        case 'edit':
          // Le panier est remplacé : jamais une vente en cours perdue en
          // silence.
          if (!ref.read(cartProvider).isEmpty &&
              !await showAmpereConfirmDialog(
                context,
                title: 'Remplacer le panier ?',
                body:
                    'Le panier de la vente contient des articles : il sera '
                    'remplacé par les lignes de ${quote.number}.',
                confirmLabel: 'Remplacer',
              )) {
            return;
          }
          await actions.editInCart(quote);
          goToDestination(ref, 'Vente');
        case 'convert':
          await _convert(context, ref, quote);
        default:
          final updated = await switch (action) {
            'send' => actions.send(quote),
            'accept' => actions.accept(quote),
            _ => actions.refuse(quote),
          };
          if (context.mounted) {
            _snack(context, '${updated.number} : ${updated.status.label}.');
          }
      }
    } on ApiException catch (error) {
      // État changé entre-temps (autre poste, expiration) : on relit.
      if (error.statusCode == 409) ref.invalidate(quotesProvider);
      if (context.mounted) _snack(context, error.userMessage);
    } on Exception {
      // Imprimante ou boîte d'impression du poste : pas une erreur serveur.
      if (context.mounted) {
        _snack(context, 'Impression impossible sur ce poste.');
      }
    }
  }

  /// Même encaissement qu'une vente : espèces dans la caisse ouverte, le reste
  /// à crédit du client avec une échéance.
  Future<void> _convert(
    BuildContext context,
    WidgetRef ref,
    Quote quote,
  ) async {
    final received = await askAmount(
      context,
      title: 'Encaisser ${formatDA(quote.totalTtc)}',
      label: 'Espèces reçues',
      confirm: 'Valider la vente',
      initial: quote.totalTtc,
      help: quote.customerId == null
          ? 'Devis comptoir : la vente doit être soldée'
          : 'Moins que le total : le reste part en crédit de ${quote.customerName}',
    );
    if (received == null || !context.mounted) return;
    final kept = received < quote.totalTtc ? received : quote.totalTtc;
    DateTime? dueDate;
    if (kept < quote.totalTtc && quote.customerId != null) {
      final today = DateUtils.dateOnly(DateTime.now());
      dueDate = await showDatePicker(
        context: context,
        helpText: 'Échéance du crédit de ${formatDA(quote.totalTtc - kept)}',
        initialDate: today.add(const Duration(days: 30)),
        firstDate: today,
        lastDate: today.add(const Duration(days: 730)),
      );
      if (dueDate == null || !context.mounted) return;
    }
    final sale = await ref
        .read(quoteActionsProvider)
        .convert(quote, paidAmount: kept, dueDate: dueDate);
    if (context.mounted) {
      final change = received - kept;
      _snack(
        context,
        'Vente ${sale.number} enregistrée'
        '${change > 0 ? ' — rendre ${formatDA(change)}' : ''}.',
      );
    }
  }
}

String _day(String iso) => iso.split('-').reversed.join('/');

StatusTone _tone(QuoteStatus status) => switch (status) {
  QuoteStatus.draft => StatusTone.neutral,
  QuoteStatus.sent => StatusTone.info,
  QuoteStatus.accepted => StatusTone.ok,
  QuoteStatus.converted => StatusTone.ok,
  QuoteStatus.refused => StatusTone.error,
  QuoteStatus.expired => StatusTone.warn,
  QuoteStatus.unknown => StatusTone.neutral,
};

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: 'Fermer', onPressed: () {}),
      ),
    );
}
