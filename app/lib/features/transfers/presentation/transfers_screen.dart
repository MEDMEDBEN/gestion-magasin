import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/transfers_controller.dart';
import '../data/transfers_models.dart';
import 'transfer_quantities_form.dart';
import 'transfer_request_form.dart';

/// Droits transferts, MIROIRS des guards serveur (`docs/permissions.md`) :
/// le magasin demande et réceptionne, le dépôt accepte, prépare et expédie.
class TransferRights {
  TransferRights(this.user)
    : canRequest =
          (user.hasRole('ADMIN') || user.hasRole('VENDEUR')) &&
          user.can('transfer.request'),
      canPrepare =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('transfer.prepare'),
      canReceive =
          (user.hasRole('ADMIN') || user.hasRole('VENDEUR')) &&
          user.can('transfer.receive'),
      canCancel = user.can('transfer.cancel');

  final AuthUser user;
  final bool canRequest;
  final bool canPrepare;
  final bool canReceive;
  final bool canCancel;

  /// Le REFUS vient du dépôt (décision du dépôt de ne pas suivre).
  bool get canRefuse =>
      canCancel && (user.hasRole('ADMIN') || user.hasRole('MAGASINIER'));

  /// L'ANNULATION vient de l'auteur de la demande — ou d'un administrateur.
  bool canCancelRequest(Transfer transfer) =>
      canCancel && (user.hasRole('ADMIN') || transfer.requestedById == user.id);
}

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

Quantity _sum(Transfer transfer, Quantity Function(TransferLine) pick) =>
    transfer.lines.fold(Quantity.zero, (sum, line) => sum + pick(line));

/// Reçu ≠ expédié : de la marchandise n'est pas arrivée. C'est le fait à
/// remarquer sur cet écran, il ne doit pas se cacher derrière un badge vert.
bool _hasShortfall(Transfer transfer) =>
    transfer.status == TransferStatus.received &&
    _sum(transfer, (l) => l.receivedQuantity) <
        _sum(transfer, (l) => l.shippedQuantity);

StatusTone _tone(Transfer transfer) => switch (transfer.status) {
  TransferStatus.requested => StatusTone.info,
  TransferStatus.accepted => StatusTone.info,
  TransferStatus.preparing => StatusTone.warn,
  TransferStatus.prepared => StatusTone.warn,
  TransferStatus.inTransit => StatusTone.warn,
  TransferStatus.received =>
    _hasShortfall(transfer) ? StatusTone.warn : StatusTone.ok,
  TransferStatus.refused => StatusTone.error,
  TransferStatus.cancelled => StatusTone.neutral,
};

/// Avancement lisible d'un transfert : demandé → préparé → expédié → reçu.
String _progress(Transfer transfer) {
  final asked = formatQuantity(_sum(transfer, (l) => l.requestedQuantity));
  String done(String verb, Quantity Function(TransferLine) pick) =>
      '$verb ${formatQuantity(_sum(transfer, pick))} sur $asked demandés';
  return switch (transfer.status) {
    TransferStatus.inTransit => done('en transit', (l) => l.shippedQuantity),
    TransferStatus.received =>
      '${done('reçu', (l) => l.receivedQuantity)}'
          '${_hasShortfall(transfer) ? ' · ÉCART, le manquant est rentré au dépôt' : ''}',
    TransferStatus.preparing ||
    TransferStatus.prepared => done('préparé', (l) => l.preparedQuantity),
    _ => '$asked demandés',
  };
}

/// Transferts magasin ↔ dépôt (spec §16 et §17). Le stock affiché vient du
/// serveur : une demande n'a rien déplacé, seule la réception rend vendable.
class TransfersScreen extends ConsumerWidget {
  const TransfersScreen({super.key, required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rights = TransferRights(user);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final transfers = ref.watch(transfersProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rights.canRequest)
          Padding(
            padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () =>
                    openFormPanel<void>(context, const TransferRequestForm()),
                icon: const Icon(LucideIcons.plus, size: 17),
                label: const Text('Nouvelle demande'),
              ),
            ),
          ),
        Expanded(
          child: transfers.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException ? error.userMessage : '$error',
              onRetry: () => ref.invalidate(transfersProvider),
            ),
            data: (items) => items.isEmpty
                ? const ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Aucun transfert',
                    message:
                        'Le magasin demande ce qui lui manque ; le dépôt '
                        'prépare, expédie, et le magasin réceptionne.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final t in items)
                        Card(
                          child: ListTile(
                            title: Text(
                              '${t.number} · ${t.lines.length} ligne(s)',
                            ),
                            subtitle: Text(
                              '${_progress(t)}'
                              '${t.priority == TransferPriority.normal ? '' : ' · priorité ${t.priority.label.toLowerCase()}'}',
                            ),
                            trailing: AmpereBadge(
                              label: _hasShortfall(t)
                                  ? 'Reçue · écart'
                                  : t.status.label,
                              tone: _tone(t),
                            ),
                            onTap: () => _openActions(context, ref, t, rights),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// Actions proposées = celles que le serveur accepterait à cet instant.
  Future<void> _openActions(
    BuildContext context,
    WidgetRef ref,
    Transfer transfer,
    TransferRights rights,
  ) async {
    final status = transfer.status;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${transfer.number} — ${status.label}'),
        children: [
          if (status == TransferStatus.requested && rights.canPrepare)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('accept'),
              child: const Text('Accepter la demande'),
            ),
          if (status.isPreparable && rights.canPrepare)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('prepare'),
              child: Text(
                status == TransferStatus.prepared
                    ? 'Corriger la préparation'
                    : 'Préparer la marchandise',
              ),
            ),
          if (status == TransferStatus.prepared && rights.canPrepare)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('ship'),
              child: const Text('Expédier vers le magasin'),
            ),
          if (status == TransferStatus.inTransit && rights.canReceive)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('receive'),
              child: const Text('Réceptionner au magasin'),
            ),
          if (status.isPreparable && rights.canRefuse)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('refuse'),
              child: const Text('Refuser la demande'),
            ),
          if (status.isPreparable && rights.canCancelRequest(transfer))
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('cancel'),
              child: const Text('Annuler ma demande'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('lines'),
            child: const Text('Voir les lignes'),
          ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;

    if (action == 'prepare' || action == 'receive') {
      await openFormPanel<void>(
        context,
        TransferQuantitiesForm(
          transfer: transfer,
          kind: action == 'prepare'
              ? TransferCountKind.prepare
              : TransferCountKind.receive,
        ),
      );
      return;
    }
    if (action == 'lines') {
      await _showLines(context, transfer);
      return;
    }
    if (action == 'ship') {
      final sure = await _confirm(
        context,
        title: 'Expédier ${transfer.number} ?',
        body:
            'La marchandise quitte le dépôt pour le transit. Le transfert ne '
            's’annule plus ensuite : il devra être réceptionné.',
        confirmLabel: 'Expédier',
      );
      if (!sure || !context.mounted) return;
    }
    if (action == 'refuse' || action == 'cancel') {
      final sure = await _confirm(
        context,
        title: action == 'refuse'
            ? 'Refuser ${transfer.number} ?'
            : 'Annuler ${transfer.number} ?',
        body:
            'Rien n’a encore quitté le dépôt. Le transfert reste dans '
            'l’historique avec son statut.',
        confirmLabel: action == 'refuse' ? 'Refuser' : 'Annuler la demande',
      );
      if (!sure || !context.mounted) return;
    }

    final actions = ref.read(transfersActionsProvider);
    try {
      final outcome = await switch (action) {
        'accept' => actions.accept(transfer.id),
        'ship' => actions.ship(transfer.id),
        'refuse' => actions.cancel(transfer.id, refuse: true),
        _ => actions.cancel(transfer.id, refuse: false),
      };
      if (context.mounted) {
        _snack(context, transferOutcomeText(outcome));
      }
    } on ApiException catch (error) {
      // État périmé (un collègue est passé avant) : on relit la liste.
      if (error.statusCode == 409) ref.invalidate(transfersProvider);
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Revenir'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return answer == true;
  }

  /// Le détail des quantités, étape par étape — l'écart éventuel se lit ici.
  Future<void> _showLines(BuildContext context, Transfer transfer) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Lignes de ${transfer.number}'),
        content: SizedBox(
          width: 460,
          child: Consumer(
            builder: (context, ref, _) {
              final products = {
                for (final p
                    in ref.watch(activeProductsProvider).value ??
                        const <Product>[])
                  p.id: p.name,
              };
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final l in transfer.lines)
                    ListTile(
                      dense: true,
                      title: Text(products[l.productId] ?? 'Produit'),
                      subtitle: Text(
                        'Demandé ${formatQuantity(l.requestedQuantity)} · '
                        'préparé ${formatQuantity(l.preparedQuantity)} · '
                        'expédié ${formatQuantity(l.shippedQuantity)} · '
                        'reçu ${formatQuantity(l.receivedQuantity)}',
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
      ),
    );
  }
}
