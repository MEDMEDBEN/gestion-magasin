import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/offline_documents_notice.dart';
import '../../../ui/navigation.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/page_kit.dart';
import '../../../ui/widgets/action_option.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../sales/application/sales_controller.dart' show printPdfProvider;
import '../application/transfers_controller.dart';
import '../data/transfers_api.dart';
import '../data/transfers_models.dart';
import '../../../ui/widgets/period_filter.dart';
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

/// Filtre de la liste, porté par les pastilles colorées.
enum _Filter { all, todo, preparing, onTheWay, received, shortfall, stopped }

bool _matches(Transfer t, _Filter f) => switch (f) {
  _Filter.all => true,
  _Filter.todo =>
    t.status == TransferStatus.requested || t.status == TransferStatus.accepted,
  _Filter.preparing =>
    t.status == TransferStatus.preparing || t.status == TransferStatus.prepared,
  _Filter.onTheWay => t.status == TransferStatus.inTransit,
  _Filter.received => t.status == TransferStatus.received && !_hasShortfall(t),
  _Filter.shortfall => _hasShortfall(t),
  _Filter.stopped =>
    t.status == TransferStatus.refused || t.status == TransferStatus.cancelled,
};

/// Transferts magasin ↔ dépôt (spec §16 et §17). Le stock affiché vient du
/// serveur : une demande n'a rien déplacé, seule la réception rend vendable.
///
/// Refonte du 2026-10-13 (MEDMEDBEN) : le circuit est affiché, les pastilles
/// filtrent, chaque transfert montre ses produits, son avancement en étapes et
/// le bouton de SA prochaine étape pour ce compte.
class TransfersScreen extends ConsumerStatefulWidget {
  const TransfersScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends ConsumerState<TransfersScreen> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final rights = TransferRights(widget.user);
    final colors = AmpereColors.of(context);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final transfers = ref.watch(transfersProvider);
    final products = {
      for (final p
          in ref.watch(activeProductsProvider).value ?? const <Product>[])
        p.id: p,
    };
    final menu = {for (final d in destinationsFor(widget.user)) d.label};

    return transfers.when(
      loading: () => const AmpereSkeletonList(rows: 5),
      error: (error, _) => ScreenStateView(
        status: error is ApiException && error.isOffline
            ? ScreenStatus.offline
            : ScreenStatus.error,
        message: error is ApiException ? error.userMessage : '$error',
        onRetry: () => ref.invalidate(transfersProvider),
      ),
      data: (list) {
        final items = list.items;
        int count(_Filter f) => items.where((t) => _matches(t, f)).length;
        final shown = items.where((t) => _matches(t, _filter)).toList();
        StatTile tile(
          _Filter f,
          IconData icon,
          String label,
          StatusTone tone,
        ) => StatTile(
          icon: icon,
          label: label,
          value: '${count(f)}',
          tone: tone,
          selected: _filter == f,
          onTap: () => setState(() => _filter = _filter == f ? _Filter.all : f),
        );
        final actions = [
          if (rights.canRequest)
            ActionTile(
              icon: LucideIcons.plus,
              title: 'Nouvelle demande',
              subtitle: 'Demander au dépôt ce qui manque au magasin.',
              tone: StatusTone.info,
              prominent: true,
              onTap: () =>
                  openFormPanel<void>(context, const TransferRequestForm()),
            ),
          if (menu.contains('Stock'))
            ActionTile(
              icon: LucideIcons.warehouse,
              title: 'Voir le stock',
              subtitle: 'Ce qu’il reste au dépôt avant de demander.',
              tone: StatusTone.neutral,
              onTap: () => goToDestination(ref, 'Stock'),
            ),
        ];

        return ListView(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 24),
          children: [
            GuideSteps(
              title: 'LE CIRCUIT D’UN TRANSFERT',
              current: items.isEmpty ? 0 : null,
              steps: const [
                ('Demande', 'Le magasin dit ce qui lui manque, et l’urgence.'),
                (
                  'Préparation',
                  'Le dépôt accepte, rassemble et compte ce qu’il envoie.',
                ),
                (
                  'Expédition',
                  'La marchandise part : elle est « en transit ».',
                ),
                (
                  'Réception',
                  'Le magasin compte ce qui arrive : c’est vendable. Un '
                      'manquant revient au dépôt.',
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (actions.isNotEmpty) ...[
              ActionGrid(children: actions),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    'TRANSFERTS',
                    style: AmpereType.label.copyWith(color: colors.ink3),
                  ),
                ),
                PeriodFilter(
                  value: ref.watch(transferPeriodProvider),
                  onChanged: ref.read(transferPeriodProvider.notifier).set,
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Filtres JUSTE au-dessus de la liste (demande MEDMEDBEN du
            // 2026-10-26) : les actions en haut, le tri près de ce qu'il trie.
            if (items.isNotEmpty) ...[
              StatGrid(
                children: [
                  tile(
                    _Filter.todo,
                    LucideIcons.inbox,
                    'À traiter',
                    StatusTone.info,
                  ),
                  tile(
                    _Filter.preparing,
                    LucideIcons.packageOpen,
                    'En préparation',
                    StatusTone.warn,
                  ),
                  tile(
                    _Filter.onTheWay,
                    LucideIcons.truck,
                    'En route',
                    StatusTone.warn,
                  ),
                  tile(
                    _Filter.received,
                    LucideIcons.circleCheck,
                    'Reçus',
                    StatusTone.ok,
                  ),
                  tile(
                    _Filter.shortfall,
                    LucideIcons.triangleAlert,
                    'Avec écart',
                    StatusTone.error,
                  ),
                  tile(
                    _Filter.stopped,
                    LucideIcons.ban,
                    'Refusés / annulés',
                    StatusTone.neutral,
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            OfflineDocumentsNotice(cachedAt: list.cachedAt),
            if (items.isEmpty)
              const AmpereInlineAlert(
                tone: StatusTone.info,
                icon: LucideIcons.info,
                message:
                    'Aucun transfert sur la période. Le magasin demande ce qui '
                    'lui manque ; le dépôt prépare, expédie, et le magasin '
                    'réceptionne.',
              )
            else if (shown.isEmpty)
              const ScreenStateView(
                status: ScreenStatus.empty,
                title: 'Rien dans cette catégorie',
              )
            else
              for (final t in shown)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _TransferCard(
                    transfer: t,
                    products: products,
                    next: _nextStep(t, rights),
                    onTap: () => _openActions(context, ref, t, rights),
                    onNext: (action) => _perform(context, ref, t, action),
                  ),
                ),
          ],
        );
      },
    );
  }

  /// La prochaine étape que CE compte peut faire, en bouton sur la carte.
  (String action, String label, IconData icon)? _nextStep(
    Transfer t,
    TransferRights rights,
  ) => switch (t.status) {
    TransferStatus.requested when rights.canPrepare => (
      'accept',
      'Accepter',
      LucideIcons.check,
    ),
    TransferStatus.accepted || TransferStatus.preparing
        when rights.canPrepare =>
      ('prepare', 'Préparer', LucideIcons.packageOpen),
    TransferStatus.prepared when rights.canPrepare => (
      'ship',
      'Envoyer au magasin',
      LucideIcons.truck,
    ),
    TransferStatus.inTransit when rights.canReceive => (
      'receive',
      'Réceptionner',
      LucideIcons.packageCheck,
    ),
    _ => null,
  };

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
            ActionOption(
              icon: LucideIcons.check,
              tone: StatusTone.ok,
              primary: true,
              onPressed: () => Navigator.of(context).pop('accept'),
              child: const Text('Accepter la demande'),
            ),
          if (status.isPreparable && rights.canPrepare)
            ActionOption(
              icon: LucideIcons.packageOpen,
              tone: StatusTone.warn,
              primary: true,
              onPressed: () => Navigator.of(context).pop('prepare'),
              child: Text(
                status == TransferStatus.prepared
                    ? 'Corriger la préparation'
                    : 'Préparer la marchandise',
              ),
            ),
          if (status == TransferStatus.prepared && rights.canPrepare)
            ActionOption(
              icon: LucideIcons.truck,
              tone: StatusTone.info,
              primary: true,
              onPressed: () => Navigator.of(context).pop('ship'),
              child: const Text('Expédier vers le magasin'),
            ),
          if (status == TransferStatus.inTransit && rights.canReceive)
            ActionOption(
              icon: LucideIcons.packageCheck,
              tone: StatusTone.ok,
              primary: true,
              onPressed: () => Navigator.of(context).pop('receive'),
              child: const Text('Réceptionner au magasin'),
            ),
          if (status.isPreparable && rights.canRefuse)
            ActionOption(
              icon: LucideIcons.circleX,
              tone: StatusTone.error,
              onPressed: () => Navigator.of(context).pop('refuse'),
              child: const Text('Refuser la demande'),
            ),
          if (status.isPreparable && rights.canCancelRequest(transfer))
            ActionOption(
              icon: LucideIcons.ban,
              tone: StatusTone.error,
              onPressed: () => Navigator.of(context).pop('cancel'),
              child: const Text('Annuler ma demande'),
            ),
          ActionOption(
            icon: LucideIcons.list,
            tone: StatusTone.neutral,
            onPressed: () => Navigator.of(context).pop('lines'),
            child: const Text('Voir les lignes'),
          ),
          ActionOption(
            icon: LucideIcons.printer,
            tone: StatusTone.neutral,
            onPressed: () => Navigator.of(context).pop('print'),
            child: const Text('Imprimer le bon de transfert'),
          ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;
    await _perform(context, ref, transfer, action);
  }

  Future<void> _perform(
    BuildContext context,
    WidgetRef ref,
    Transfer transfer,
    String action,
  ) async {
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
    if (action == 'print') {
      try {
        final pdf = await ref.read(transfersApiProvider).document(transfer.id);
        await ref.read(printPdfProvider)(pdf, '${transfer.number}.pdf');
      } on ApiException catch (error) {
        if (context.mounted) _snack(context, error.userMessage);
      } on Exception {
        // Imprimante ou boîte d'impression du poste : pas une erreur serveur.
        if (context.mounted) {
          _snack(context, 'Impression impossible sur ce poste.');
        }
      }
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

/// Un transfert : ses produits, ses étapes en pastilles, l'écart en rouge et
/// le bouton de la prochaine étape.
class _TransferCard extends StatelessWidget {
  const _TransferCard({
    required this.transfer,
    required this.products,
    required this.next,
    required this.onTap,
    required this.onNext,
  });

  final Transfer transfer;
  final Map<String, Product> products;
  final (String, String, IconData)? next;
  final VoidCallback onTap;
  final ValueChanged<String> onNext;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final t = transfer;
    final tone = _tone(t);
    final shortfall = _hasShortfall(t);
    final stopped =
        t.status == TransferStatus.refused ||
        t.status == TransferStatus.cancelled;
    // 0 demandé, 1 préparé, 2 expédié, 3 reçu.
    final reached = switch (t.status) {
      TransferStatus.requested || TransferStatus.accepted => 0,
      TransferStatus.preparing || TransferStatus.prepared => 1,
      TransferStatus.inTransit => 2,
      TransferStatus.received => 3,
      _ => -1,
    };
    final names = [
      for (final l in t.lines.take(3))
        '${products[l.productId]?.name ?? 'Produit'} ×'
            '${formatQuantity(l.requestedQuantity)}',
      if (t.lines.length > 3) '+${t.lines.length - 3}',
    ].join(' · ');
    final urgent = t.priority != TransferPriority.normal;

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: shortfall
                  ? colors.error.withValues(alpha: 0.6)
                  : urgent && !stopped && reached < 3
                  ? colors.warn.withValues(alpha: 0.6)
                  : colors.line,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    LucideIcons.arrowLeftRight,
                    size: 18,
                    color: tone.foreground(colors),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${t.number} · ${t.lines.length} ligne(s)',
                      style: AmpereType.rowTitle.copyWith(color: colors.ink),
                    ),
                  ),
                  AmpereBadge(
                    label: shortfall ? 'Reçue · écart' : t.status.label,
                    tone: tone,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                names,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AmpereType.body.copyWith(color: colors.ink2),
              ),
              Text(
                '${_progress(t)}'
                '${urgent ? ' · priorité ${t.priority.label.toLowerCase()}' : ''}',
                style: AmpereType.meta.copyWith(
                  color: shortfall ? colors.error : colors.ink3,
                ),
              ),
              if (!stopped) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (final (i, step) in const [
                      'Demandé',
                      'Préparé',
                      'Expédié',
                      'Reçu',
                    ].indexed) ...[
                      if (i > 0)
                        Expanded(
                          child: Container(
                            height: 2,
                            color: i <= reached ? colors.ok : colors.line,
                          ),
                        ),
                      _Step(
                        label: step,
                        done: i <= reached,
                        current: i == reached && reached < 3,
                      ),
                    ],
                  ],
                ),
              ],
              if (next case (final action, final label, final icon)?) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.ok,
                      foregroundColor: colors.bg,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => onNext(action),
                    icon: Icon(icon, size: 16),
                    label: Text(label),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.label, required this.done, required this.current});

  final String label;
  final bool done;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final color = current
        ? colors.warn
        : done
        ? colors.ok
        : colors.ink3;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          done ? LucideIcons.circleCheck : LucideIcons.circle,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 4),
        Text(label, style: AmpereType.meta.copyWith(color: color)),
      ],
    );
  }
}
