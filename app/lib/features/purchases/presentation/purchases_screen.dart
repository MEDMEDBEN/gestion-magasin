import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/export_button.dart';
import '../../../ui/navigation.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/page_kit.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../suppliers/application/suppliers_controller.dart';
import '../../receptions/application/receptions_controller.dart';
import '../../receptions/data/receptions_api.dart';
import '../../receptions/presentation/reception_form.dart';
import '../../sales/application/sales_controller.dart' show printPdfProvider;
import '../application/purchases_controller.dart';
import '../data/purchases_api.dart';
import '../data/purchases_models.dart';
import '../../../ui/widgets/period_filter.dart';
import 'purchase_order_form.dart';

/// Droits achats, MIROIRS des guards serveur (`docs/permissions.md`) :
/// créer/modifier = ADMIN|MAGASINIER + purchase.create ; confirmer/annuler =
/// ADMIN + purchase.confirm.
class PurchaseRights {
  PurchaseRights(AuthUser user)
    : canWrite =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('purchase.create'),
      canConfirm = user.hasRole('ADMIN') && user.can('purchase.confirm'),
      canReceive =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('reception.create');

  final bool canWrite;
  final bool canConfirm;
  final bool canReceive;
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

StatusTone _tone(PurchaseStatus status) => switch (status) {
  PurchaseStatus.draft => StatusTone.neutral,
  PurchaseStatus.ordered => StatusTone.info,
  PurchaseStatus.confirmed => StatusTone.info,
  PurchaseStatus.partiallyReceived => StatusTone.warn,
  PurchaseStatus.received => StatusTone.ok,
  PurchaseStatus.closed => StatusTone.neutral,
  PurchaseStatus.cancelled => StatusTone.error,
};

/// Filtre de la liste, porté par les tuiles colorées.
enum _Filter { all, draft, waiting, partial, late, done }

bool _matches(PurchaseOrder o, _Filter f) => switch (f) {
  _Filter.all => true,
  _Filter.draft => o.status == PurchaseStatus.draft,
  _Filter.waiting =>
    o.status == PurchaseStatus.ordered || o.status == PurchaseStatus.confirmed,
  _Filter.partial => o.status == PurchaseStatus.partiallyReceived,
  _Filter.late => _late(o),
  _Filter.done =>
    o.status == PurchaseStatus.received || o.status == PurchaseStatus.closed,
};

/// Achats : commandes fournisseurs, de la préparation à la réception.
///
/// Refonte du 2026-10-13 (MEDMEDBEN) : le déroulé est affiché, les chiffres
/// clés filtrent, chaque commande dit sa prochaine étape, et la réception se
/// lance d'un geste depuis la carte.
class PurchasesScreen extends ConsumerStatefulWidget {
  const PurchasesScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends ConsumerState<PurchasesScreen> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final rights = PurchaseRights(user);
    final colors = AmpereColors.of(context);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final orders = ref.watch(purchaseOrdersProvider);
    final suppliers = {
      for (final s in ref.watch(supplierSearchProvider('')).value ?? const [])
        s.id: s.name,
    };
    final menu = {for (final d in destinationsFor(user)) d.label};

    final toolbar = Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        PeriodFilter(
          value: ref.watch(purchasePeriodProvider),
          onChanged: ref.read(purchasePeriodProvider.notifier).set,
        ),
        // Miroirs des gardes serveur de `GET /purchase-orders/export` et
        // `GET /receptions/export`.
        if (rights.canWrite || rights.canReceive)
          ExportButton(
            targets: [
              if (rights.canWrite)
                ExportTarget(
                  'Commandes (12 mois)',
                  ref.read(purchasesApiProvider).exportOrders,
                ),
              if (rights.canReceive)
                ExportTarget(
                  'Réceptions (12 mois)',
                  ref.read(receptionsApiProvider).exportReceptions,
                ),
            ],
          ),
      ],
    );

    final actions = [
      if (rights.canWrite)
        ActionTile(
          icon: LucideIcons.plus,
          title: 'Nouvelle commande',
          subtitle: 'Choisir le fournisseur et les produits à commander.',
          tone: StatusTone.info,
          prominent: true,
          onTap: () => openFormPanel<void>(context, const PurchaseOrderForm()),
        ),
      if (menu.contains('Réappro'))
        ActionTile(
          icon: LucideIcons.shoppingBasket,
          title: 'Que racheter ?',
          subtitle: 'Les produits sous leur seuil, prêts à commander.',
          tone: StatusTone.warn,
          onTap: () => goToDestination(ref, 'Réappro'),
        ),
      if (menu.contains('Fournisseurs'))
        ActionTile(
          icon: LucideIcons.truck,
          title: 'Fournisseurs',
          subtitle: 'Fiches, dettes, paiements et retours.',
          tone: StatusTone.neutral,
          onTap: () => goToDestination(ref, 'Fournisseurs'),
        ),
      if (menu.contains('Stock'))
        ActionTile(
          icon: LucideIcons.packagePlus,
          title: 'Stock sans achat',
          subtitle: 'Déjà en rayon ? Stock → « Ajouter du stock ».',
          tone: StatusTone.ok,
          onTap: () => goToDestination(ref, 'Stock'),
        ),
    ];

    return orders.when(
      loading: () => const AmpereSkeletonList(rows: 5),
      error: (error, _) => ScreenStateView(
        status: error is ApiException && error.isOffline
            ? ScreenStatus.offline
            : ScreenStatus.error,
        message: error is ApiException ? error.userMessage : '$error',
        onRetry: () => ref.invalidate(purchaseOrdersProvider),
      ),
      data: (items) {
        int count(_Filter f) => items.where((o) => _matches(o, f)).length;
        final shown = items.where((o) => _matches(o, _filter)).toList();
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

        return ListView(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 24),
          children: [
            GuideSteps(
              title: 'D’UNE COMMANDE À LA MARCHANDISE EN STOCK',
              current: items.isEmpty ? 0 : null,
              steps: const [
                (
                  'Préparer',
                  'Fournisseur, produits, quantités, prix d’achat : un '
                      'brouillon modifiable.',
                ),
                (
                  'Envoyer',
                  'Imprimez le bon ou copiez le message pour le fournisseur.',
                ),
                (
                  'Confirmer',
                  'L’administrateur engage la commande (et la dette).',
                ),
                (
                  'Réceptionner',
                  'Ce qui arrive vraiment entre en stock, même en plusieurs '
                      'fois ; le coût d’achat est mis à jour.',
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (actions.isNotEmpty) ...[
              ActionGrid(children: actions),
              const SizedBox(height: 14),
            ],
            if (items.isNotEmpty) ...[
              StatGrid(
                children: [
                  tile(
                    _Filter.draft,
                    LucideIcons.filePen,
                    'Brouillons',
                    StatusTone.neutral,
                  ),
                  tile(
                    _Filter.waiting,
                    LucideIcons.hourglass,
                    'À recevoir',
                    StatusTone.info,
                  ),
                  tile(
                    _Filter.partial,
                    LucideIcons.packageOpen,
                    'Partiellement reçues',
                    StatusTone.warn,
                  ),
                  tile(
                    _Filter.late,
                    LucideIcons.alarmClock,
                    'En retard',
                    StatusTone.error,
                  ),
                  tile(
                    _Filter.done,
                    LucideIcons.circleCheck,
                    'Terminées',
                    StatusTone.ok,
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    'COMMANDES',
                    style: AmpereType.label.copyWith(color: colors.ink3),
                  ),
                ),
                if (_filter != _Filter.all)
                  TextButton.icon(
                    onPressed: () => setState(() => _filter = _Filter.all),
                    icon: const Icon(LucideIcons.x, size: 15),
                    label: const Text('Tout afficher'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            toolbar,
            const SizedBox(height: 10),
            if (items.isEmpty)
              const AmpereInlineAlert(
                tone: StatusTone.info,
                icon: LucideIcons.info,
                message:
                    'Aucune commande sur la période. Préparez une commande '
                    'fournisseur : elle sera réceptionnée au dépôt.',
              )
            else if (shown.isEmpty)
              const ScreenStateView(
                status: ScreenStatus.empty,
                title: 'Rien dans cette catégorie',
              )
            else
              for (final o in shown)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _OrderCard(
                    order: o,
                    supplier: suppliers[o.supplierId] ?? 'Fournisseur',
                    rights: rights,
                    onTap: () => _openActions(context, ref, o, rights),
                    onReceive: () =>
                        openFormPanel<void>(context, ReceptionForm(order: o)),
                  ),
                ),
          ],
        );
      },
    );
  }

  /// Message à modèle fixe (P2 n°22) : à copier dans un e-mail ou WhatsApp —
  /// aucune intégration d'envoi (spec §28 : « si intégration »).
  Future<void> _showMessage(
    BuildContext context,
    WidgetRef ref,
    PurchaseOrder order,
  ) async {
    final Map<String, dynamic> message;
    try {
      message = await ref.read(purchasesApiProvider).message(order.id);
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
      return;
    }
    if (!context.mounted) return;
    final text = message['text'] as String;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Message à ${message['supplierName']}'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(text),
              const SizedBox(height: 12),
              Text(
                [
                  if (message['email'] != null) 'E-mail : ${message['email']}',
                  if (message['phone'] != null)
                    'Téléphone / WhatsApp : ${message['phone']}',
                ].join('\n'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Fermer'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              if (context.mounted) {
                _snack(
                  context,
                  'Message copié : collez-le dans l’e-mail ou WhatsApp.',
                );
              }
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copier le message'),
          ),
        ],
      ),
    );
  }

  Future<void> _openActions(
    BuildContext context,
    WidgetRef ref,
    PurchaseOrder order,
    PurchaseRights rights,
  ) async {
    final editable = order.status.isEditable;
    // Miroir du serveur : on ne réceptionne qu'une commande engagée.
    final receivable =
        order.status == PurchaseStatus.confirmed ||
        order.status == PurchaseStatus.partiallyReceived;
    final colors = AmpereColors.of(context);
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${order.number} — ${order.status.label}'),
        children: [
          if (editable && rights.canWrite)
            _option(
              context,
              'edit',
              LucideIcons.pencil,
              colors.ink2,
              'Modifier les lignes',
            ),
          if (order.status == PurchaseStatus.draft && rights.canWrite)
            _option(
              context,
              'ordered',
              LucideIcons.send,
              colors.info,
              'Marquer comme envoyée au fournisseur',
            ),
          if (editable && rights.canConfirm)
            _option(
              context,
              'confirm',
              LucideIcons.badgeCheck,
              colors.ok,
              'Confirmer la commande',
            ),
          // Refusée par le serveur dès qu'une réception existe.
          if ((editable || order.status == PurchaseStatus.confirmed) &&
              rights.canConfirm)
            _option(
              context,
              'cancel',
              LucideIcons.ban,
              colors.error,
              'Annuler la commande',
            ),
          if (order.status == PurchaseStatus.partiallyReceived &&
              rights.canConfirm)
            _option(
              context,
              'close',
              LucideIcons.archiveX,
              colors.warn,
              'Clôturer le reliquat',
            ),
          if (receivable && rights.canReceive)
            _option(
              context,
              'receive',
              LucideIcons.packageCheck,
              colors.ok,
              'Réceptionner la marchandise',
            ),
          if (!editable && rights.canReceive)
            _option(
              context,
              'receptions',
              LucideIcons.history,
              colors.ink2,
              'Réceptions enregistrées',
            ),
          if (!editable)
            _option(
              context,
              'view',
              LucideIcons.eye,
              colors.ink2,
              'Voir les lignes',
            ),
          // Commande engagée : seules ses dates changent (nouveau délai).
          if (!editable &&
              order.status != PurchaseStatus.cancelled &&
              rights.canWrite)
            _option(
              context,
              'dates',
              LucideIcons.calendarClock,
              colors.ink2,
              'Changer les dates',
            ),
          _option(
            context,
            'print',
            LucideIcons.printer,
            colors.ink2,
            'Imprimer le bon de commande',
          ),
          if (order.status != PurchaseStatus.cancelled)
            _option(
              context,
              'message',
              LucideIcons.messageSquareText,
              colors.info,
              'Message au fournisseur',
            ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;
    if (action == 'print') {
      try {
        final pdf = await ref.read(purchasesApiProvider).document(order.id);
        await ref.read(printPdfProvider)(pdf, '${order.number}.pdf');
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
    if (action == 'message') {
      await _showMessage(context, ref, order);
      return;
    }
    if (action == 'receive') {
      await openFormPanel<void>(context, ReceptionForm(order: order));
      return;
    }
    if (action == 'dates') {
      await _changeDates(context, ref, order);
      return;
    }
    if (action == 'close') {
      await _closeRemainder(context, ref, order);
      return;
    }
    if (action == 'receptions') {
      await _showReceptions(context, ref, order);
      return;
    }
    if (action == 'edit' || action == 'view') {
      await openFormPanel<void>(
        context,
        PurchaseOrderForm(existing: order, readOnly: action == 'view'),
      );
      return;
    }
    if (action == 'cancel') {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Annuler ${order.number} ?'),
          content: const Text(
            'La commande reste dans l’historique avec le statut « Annulée ».',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Garder'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Annuler la commande'),
            ),
          ],
        ),
      );
      if (sure != true || !context.mounted) return;
    }
    final actions = ref.read(purchasesActionsProvider);
    try {
      final updated = await switch (action) {
        'ordered' => actions.markOrdered(order.id),
        'confirm' => actions.confirm(order),
        _ => actions.cancel(order.id),
      };
      if (context.mounted) {
        _snack(context, '${updated.number} : ${updated.status.label}.');
      }
    } on ApiException catch (error) {
      // Version périmée : la liste est relue pour montrer la commande actuelle.
      if (error.statusCode == 409) ref.invalidate(purchaseOrdersProvider);
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  /// Reliquat abandonné : motif obligatoire, ce qui est reçu reste reçu.
  /// Livraison prévue et échéance d'une commande engagée, choisies l'une
  /// après l'autre (Annuler garde la date actuelle).
  Future<void> _changeDates(
    BuildContext context,
    WidgetRef ref,
    PurchaseOrder order,
  ) async {
    final today = DateUtils.dateOnly(DateTime.now());
    Future<DateTime?> pick(String help, DateTime? current) {
      final initial = current?.toLocal() ?? today;
      return showDatePicker(
        context: context,
        helpText: help,
        initialDate: initial,
        firstDate: initial.isBefore(today) ? initial : today,
        lastDate: today.add(const Duration(days: 730)),
      );
    }

    final expected =
        await pick('Nouvelle livraison prévue', order.expectedDate) ??
        order.expectedDate?.toLocal();
    if (!context.mounted) return;
    final due =
        await pick('Échéance de paiement', order.dueDate) ??
        order.dueDate?.toLocal();
    if (!context.mounted) return;
    try {
      await ref
          .read(purchasesActionsProvider)
          .setDates(order.id, expectedDate: expected, dueDate: due);
      if (context.mounted) {
        _snack(context, 'Dates de ${order.number} mises à jour.');
      }
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  Future<void> _closeRemainder(
    BuildContext context,
    WidgetRef ref,
    PurchaseOrder order,
  ) async {
    final confirmed = await showDialog<String>(
      context: context,
      builder: (context) => _CloseRemainderDialog(number: order.number),
    );
    if (confirmed == null || !context.mounted) return;
    try {
      final updated = await ref
          .read(purchasesActionsProvider)
          .close(order.id, confirmed);
      if (context.mounted) {
        _snack(context, '${updated.number} : ${updated.status.label}.');
      }
    } on ApiException catch (error) {
      if (error.statusCode == 409) ref.invalidate(purchaseOrdersProvider);
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  /// Historique : une commande peut avoir plusieurs réceptions partielles.
  Future<void> _showReceptions(
    BuildContext context,
    WidgetRef ref,
    PurchaseOrder order,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Réceptions de ${order.number}'),
        content: SizedBox(
          width: 420,
          child: Consumer(
            builder: (context, ref, _) => ref
                .watch(orderReceptionsProvider(order.id))
                .when(
                  loading: () => const AmpereSkeletonList(rows: 2),
                  error: (error, _) => Text(
                    error is ApiException ? error.userMessage : '$error',
                  ),
                  data: (items) => items.isEmpty
                      ? const Text('Aucune réception pour cette commande.')
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final r in items)
                              ListTile(
                                title: Text(r.number),
                                subtitle: Text(
                                  '${r.lines.length} ligne(s) · '
                                  '${formatDA(r.totalTtc)} TTC',
                                ),
                              ),
                          ],
                        ),
                ),
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

/// Un geste du menu d'une commande : icône colorée + libellé.
Widget _option(
  BuildContext context,
  String value,
  IconData icon,
  Color color,
  String label,
) => SimpleDialogOption(
  onPressed: () => Navigator.of(context).pop(value),
  child: Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
      ],
    ),
  ),
);

/// Clôture du reliquat : motif obligatoire. Dialogue à état pour que le
/// contrôleur de texte vive jusqu'à la fin de l'animation de fermeture.
class _CloseRemainderDialog extends StatefulWidget {
  const _CloseRemainderDialog({required this.number});

  final String number;

  @override
  State<_CloseRemainderDialog> createState() => _CloseRemainderDialogState();
}

class _CloseRemainderDialogState extends State<_CloseRemainderDialog> {
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
    return AlertDialog(
      title: Text('Clôturer le reliquat de ${widget.number} ?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Ce qui est déjà reçu reste reçu. La commande sort des en-cours et '
            'n’accepte plus aucune réception.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            autofocus: true,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: 'Motif',
              hintText: 'Rupture définitive chez le fournisseur',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Garder ouverte'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Clôturer')),
      ],
    );
  }
}

/// Livraison attendue et dépassée, pour une commande engagée non soldée.
bool _late(PurchaseOrder o) {
  final expected = o.expectedDate;
  if (expected == null) return false;
  final engaged =
      o.status == PurchaseStatus.confirmed ||
      o.status == PurchaseStatus.partiallyReceived;
  return engaged &&
      DateUtils.dateOnly(
        expected.toLocal(),
      ).isBefore(DateUtils.dateOnly(DateTime.now()));
}

/// Une commande : fournisseur, montant, état en couleur, et sa PROCHAINE
/// étape — la réception se lance d'ici.
class _OrderCard extends StatelessWidget {
  const _OrderCard({
    required this.order,
    required this.supplier,
    required this.rights,
    required this.onTap,
    required this.onReceive,
  });

  final PurchaseOrder order;
  final String supplier;
  final PurchaseRights rights;
  final VoidCallback onTap;
  final VoidCallback onReceive;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final o = order;
    final late = _late(o);
    final tone = late ? StatusTone.error : _tone(o.status);
    final receivable =
        (o.status == PurchaseStatus.confirmed ||
            o.status == PurchaseStatus.partiallyReceived) &&
        rights.canReceive;
    final next = switch (o.status) {
      PurchaseStatus.draft => 'Prochaine étape : envoyer au fournisseur',
      PurchaseStatus.ordered => 'Prochaine étape : confirmer (administrateur)',
      PurchaseStatus.confirmed => 'Prochaine étape : réceptionner',
      PurchaseStatus.partiallyReceived =>
        'Reste à recevoir — ou clôturer le reliquat',
      _ => null,
    };
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
              color: tone == StatusTone.neutral
                  ? colors.line
                  : tone.foreground(colors).withValues(alpha: 0.45),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: tone.background(colors),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      LucideIcons.truck,
                      size: 18,
                      color: tone.foreground(colors),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${o.number} · $supplier',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AmpereType.rowTitle.copyWith(
                            color: colors.ink,
                          ),
                        ),
                        Text(
                          [
                            '${o.lines.length} ligne(s)',
                            if (o.expectedDate != null && !late)
                              'livraison ${formatDate(o.expectedDate!.toLocal())}',
                            if (o.dueDate != null)
                              'échéance ${formatDate(o.dueDate!.toLocal())}',
                          ].join(' · '),
                          style: AmpereType.meta.copyWith(color: colors.ink3),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${formatDA(o.totalTtc)} TTC',
                        style: AmpereType.bodyStrong.copyWith(
                          color: colors.ink,
                          fontFeatures: AmpereType.tabular,
                        ),
                      ),
                      const SizedBox(height: 4),
                      AmpereBadge(label: o.status.label, tone: _tone(o.status)),
                    ],
                  ),
                ],
              ),
              if (late || next != null || receivable) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        late
                            ? 'EN RETARD (prévue le ${formatDate(o.expectedDate!.toLocal())})'
                            : next ?? '',
                        style: AmpereType.meta.copyWith(
                          color: late ? colors.error : colors.ink2,
                          fontWeight: late ? FontWeight.w700 : null,
                        ),
                      ),
                    ),
                    if (receivable)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: colors.ok,
                          foregroundColor: colors.bg,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: onReceive,
                        icon: const Icon(LucideIcons.packageCheck, size: 16),
                        label: const Text('Réceptionner'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
