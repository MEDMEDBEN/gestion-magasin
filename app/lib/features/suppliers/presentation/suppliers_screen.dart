import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/dates.dart';
import '../../../core/money.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/history_dialog.dart';
import '../../purchases/data/purchases_api.dart';
import '../../../core/file_export.dart';
import '../../../core/file_import.dart';
import '../../../ui/widgets/export_button.dart';
import '../../../ui/widgets/import_button.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../payments/presentation/payment_history_dialog.dart';
import '../data/suppliers_api.dart';
import '../application/suppliers_controller.dart';
import '../data/suppliers_models.dart';
import '../../sales/application/sales_controller.dart';
import '../../../ui/widgets/contact_profile.dart';
import '../../../ui/widgets/ampere_controls.dart';
import 'supplier_return_dialog.dart';

/// Droits fournisseurs, MIROIRS des guards serveur (`docs/permissions.md`) :
/// le vendeur n'a AUCUN accès, seul l'admin écrit et paie.
class SupplierRights {
  SupplierRights(AuthUser user)
    : canRead =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('supplier.read'),
      canWrite = user.hasRole('ADMIN') && user.can('supplier.write'),
      canPay = user.hasRole('ADMIN') && user.can('supplier.payment.create'),
      // Garde de la liste des commandes (`GET /purchase-orders`).
      canSeePurchases =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('purchase.create'),
      // Retour de marchandise : gardes de la réception (P1 bis n°21l).
      canReturn =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('reception.create');

  /// Contre-passation : même droit que le paiement (ADMIN).

  final bool canRead;
  final bool canWrite;
  final bool canPay;
  final bool canSeePurchases;
  final bool canReturn;
}

/// Évolution du dernier prix d'achat par rapport au précédent : « (+4,5 %) »,
/// rien sans prix précédent (ou nul) ni sous 0,05 %.
@visibleForTesting
String priceEvolution(int? previous, int last) {
  if (previous == null || previous == 0) return '';
  final percent = (last - previous) * 100 / previous;
  final text = percent.toStringAsFixed(1).replaceAll('.', ',');
  // Arrondi à 0 : aucune évolution lisible (jamais « -0,0 % »).
  if (text == '0,0' || text == '-0,0') return '';
  return ' (${percent > 0 ? '+' : ''}$text %)';
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

class SuppliersScreen extends ConsumerStatefulWidget {
  const SuppliersScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends ConsumerState<SuppliersScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final rights = SupplierRights(widget.user);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final suppliers = ref.watch(supplierSearchProvider(_query));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  style: AmpereType.input.copyWith(color: colors.ink),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(LucideIcons.search, size: 17),
                    hintText: 'Nom ou téléphone',
                  ),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
              // `POST /imports/suppliers` : même garde que la création (ADMIN).
              if (rights.canWrite)
                ImportButton(
                  kind: ImportKind.suppliers,
                  onImported: () => ref.invalidate(supplierSearchProvider),
                ),
              ExportButton(
                targets: [
                  ExportTarget(
                    'Fournisseurs',
                    ref.read(suppliersApiProvider).exportSuppliers,
                  ),
                  ExportTarget(
                    'Dettes fournisseurs',
                    (format) => ref
                        .read(suppliersApiProvider)
                        .exportSuppliers(format, debtOnly: true),
                  ),
                ],
              ),
              if (rights.canWrite) ...[
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: () => _openForm(null),
                  icon: const Icon(LucideIcons.plus, size: 17),
                  label: const Text('Nouveau'),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: suppliers.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException ? error.userMessage : '$error',
              onRetry: () => ref.invalidate(supplierSearchProvider),
            ),
            data: (items) => items.isEmpty
                ? ScreenStateView(
                    status: _query.isEmpty
                        ? ScreenStatus.empty
                        : ScreenStatus.noResults,
                    title: _query.isEmpty ? 'Aucun fournisseur' : null,
                    message: _query.isEmpty
                        ? 'Créez les fiches de vos fournisseurs et reprenez ce '
                              'que vous leur devez déjà.'
                        : null,
                    searchTerm: _query.isEmpty ? null : _query,
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final s in items)
                        Card(
                          child: ListTile(
                            title: Text(s.name),
                            subtitle: Text(
                              [
                                s.phone ?? 'Sans téléphone',
                                if (s.contactName != null) s.contactName!,
                                'payé ${formatDA(s.paidAmount)}',
                              ].join(' · '),
                            ),
                            trailing: AmpereBadge(
                              label: s.balanceDue > 0
                                  ? 'Dette ${formatDA(s.balanceDue)}'
                                  : 'À jour',
                              tone: s.balanceDue > 0
                                  ? StatusTone.warn
                                  : StatusTone.ok,
                            ),
                            onTap: () => _openActions(s, rights),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// « Supprimer » = retirer des listes : achats et paiements restent ; le
  /// serveur refuse tant qu'il reste un solde (il le dit).
  Future<void> _delete(Supplier supplier) async {
    final confirmed = await showAmpereConfirmDialog(
      context,
      title: 'Supprimer « ${supplier.name} » ?',
      body:
          'Le fournisseur disparaît des listes et des commandes. Ses achats '
          'et ses paiements restent dans l’historique. Impossible tant qu’il '
          'reste quelque chose à lui payer.',
      confirmLabel: 'Supprimer',
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(suppliersApiProvider).update(supplier.id, {
        'isActive': false,
      });
      ref.invalidate(supplierSearchProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${supplier.name} supprimé des fournisseurs.'),
          ),
        );
      }
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.userMessage)));
      }
    }
  }

  Future<void> _openActions(Supplier supplier, SupplierRights rights) async {
    // Fiche CONTACT (2026-10-06) : coordonnées, compte, actions, supprimer.
    final action = await showContactProfile(
      context,
      name: supplier.name,
      kind: 'Fournisseur',
      contactName: supplier.contactName,
      phone: supplier.phone,
      email: supplier.email,
      address: supplier.address,
      notes: supplier.notes,
      figures: [
        (
          label: 'Marchandise reçue',
          value: formatDA(supplier.receivedAmount),
          tone: StatusTone.neutral,
        ),
        (
          label: 'Payé',
          value: formatDA(supplier.paidAmount),
          tone: StatusTone.neutral,
        ),
        (
          label: 'Reste dû',
          value: formatDA(supplier.balanceDue),
          tone: supplier.balanceDue > 0 ? StatusTone.warn : StatusTone.ok,
        ),
      ],
      actions: [
        if (rights.canPay && supplier.balanceDue > 0)
          (
            icon: LucideIcons.banknote,
            label: 'Enregistrer un paiement',
            value: 'pay',
          ),
        if (rights.canSeePurchases)
          (
            icon: LucideIcons.package,
            label: 'Historique des achats',
            value: 'purchases',
          ),
        (icon: LucideIcons.chartLine, label: 'Indicateurs', value: 'stats'),
        (
          icon: LucideIcons.fileText,
          label: 'Relevé de compte (PDF)',
          value: 'statement',
        ),
        if (rights.canReturn) ...[
          (
            icon: LucideIcons.undo2,
            label: 'Retour de marchandise',
            value: 'return',
          ),
          (
            icon: LucideIcons.fileText,
            label: 'Retours de marchandise',
            value: 'returns',
          ),
        ],
        (
          icon: LucideIcons.history,
          label: 'Historique des paiements',
          value: 'history',
        ),
        if (rights.canWrite)
          (icon: LucideIcons.pencil, label: 'Modifier la fiche', value: 'edit'),
      ],
      // `PATCH /suppliers/:id` : ADMIN + supplier.write (comme la fiche).
      canDelete: rights.canWrite,
    );
    if (!mounted) return;
    if (action == contactDeleteAction) return _delete(supplier);
    if (action == 'pay') return _pay(supplier);
    if (action == 'edit') return _openForm(supplier);
    if (action == 'return') return _returnGoods(supplier);
    if (action == 'statement') {
      // P1 bis n°21n : enregistré sur ce poste, comme les autres exports.
      try {
        final path = await ref.read(saveExportProvider)(
          await ref
              .read(suppliersApiProvider)
              .supplierStatement(supplier.id, ExportFormat.pdf),
        );
        if (mounted) _snack(context, 'Enregistré sur ce poste : $path');
      } on ApiException catch (error) {
        if (mounted) _snack(context, error.userMessage);
      } on Exception {
        if (mounted) {
          _snack(context, 'Le relevé n’a pas pu être enregistré sur ce poste.');
        }
      }
      return;
    }
    if (action == 'stats') {
      // P1 bis n°21m : lu des réceptions (le reçu fait foi, comme la dette).
      final api = ref.read(suppliersApiProvider);
      await showHistory(
        context,
        title: 'Indicateurs — ${supplier.name}',
        empty: 'Rien encore reçu de ce fournisseur.',
        load: () async {
          final stats = await api.stats(supplier.id);
          return [
            (
              title: 'Total acheté',
              subtitle: 'Marchandise reçue, nette des retours',
              trailing: formatDA(supplier.receivedAmount),
              at: null,
            ),
            (
              title: 'Produits fournis',
              subtitle: 'Produits différents reçus',
              trailing: '${stats.productCount}',
              at: null,
            ),
            (
              title: 'Livraisons à l’heure',
              subtitle: stats.deliveriesWithDate == 0
                  ? 'Aucune commande avec date de livraison prévue'
                  : '${stats.deliveriesOnTime} sur ${stats.deliveriesWithDate} '
                        'réceptions de commandes datées',
              trailing: stats.deliveriesWithDate == 0
                  ? '—'
                  : '${(stats.deliveriesOnTime * 100 / stats.deliveriesWithDate).round()} %',
              at: null,
            ),
            for (final p in stats.prices)
              (
                title: '${p.sku} — ${p.name}',
                subtitle:
                    'Reçu le ${formatDate(p.lastReceivedAt.toLocal())} · '
                    '${p.receptions} réception(s) · premier prix '
                    '${formatDA(p.firstPriceHt)}'
                    '${p.previousPriceHt == null ? '' : ' · précédent ${formatDA(p.previousPriceHt!)}'}',
                trailing:
                    '${formatDA(p.lastPriceHt)} HT${priceEvolution(p.previousPriceHt, p.lastPriceHt)}',
                // Indicateurs, pas un historique : aucun filtre par dates.
                at: null,
              ),
          ];
        },
      );
      return;
    }
    if (action == 'returns') {
      final actions = ref.read(suppliersActionsProvider);
      await showHistory(
        context,
        title: 'Retours — ${supplier.name}',
        empty: 'Aucune marchandise renvoyée à ce fournisseur.',
        load: () async => [
          for (final r in await actions.returns(supplier.id))
            (
              title: r['number'] as String,
              subtitle:
                  '${formatDate(DateTime.parse(r['createdAt'] as String).toLocal())} · ${r['reason']}',
              trailing: formatDA(r['totalTtc'] as int),
              at: DateTime.parse(r['createdAt'] as String),
            ),
        ],
      );
      return;
    }
    if (action == 'purchases') {
      final api = ref.read(purchasesApiProvider);
      await showHistory(
        context,
        title: 'Achats — ${supplier.name}',
        empty: 'Aucune commande passée à ce fournisseur.',
        load: () async => [
          for (final o in (await api.list(supplierId: supplier.id)).data)
            (
              title: '${o.number} · ${o.status.label}',
              subtitle:
                  '${formatDate(o.orderDate)} · ${o.lines.length} ligne(s)',
              trailing: formatDA(o.totalTtc),
              at: o.orderDate,
            ),
        ],
      );
      return;
    }
    if (action == 'history') {
      final actions = ref.read(suppliersActionsProvider);
      await showPaymentHistory(
        context,
        title: 'Paiements — ${supplier.name}',
        load: () => actions.payments(supplier.id),
        onReverse: rights.canPay
            ? (payment, reason) => actions.reversePayment(payment.id, reason)
            : null,
      );
    }
  }

  /// Retour de marchandise, puis impression du bon qui l'accompagne.
  Future<void> _returnGoods(Supplier supplier) async {
    final done = await showSupplierReturnDialog(context, supplier);
    if (done == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Retour ${done['number']} enregistré — dette réduite de '
            '${formatDA(done['totalTtc'] as int)}',
          ),
          action: SnackBarAction(
            label: 'Imprimer le bon',
            onPressed: () async {
              try {
                final pdf = await ref
                    .read(suppliersActionsProvider)
                    .returnDocument(done['id'] as String);
                await ref.read(printPdfProvider)(pdf, '${done['number']}.pdf');
              } on Exception {
                if (mounted) _snack(context, 'Impression impossible.');
              }
            },
          ),
        ),
      );
  }

  Future<void> _openForm(Supplier? existing) =>
      openFormPanel<void>(context, _SupplierForm(existing: existing));

  Future<void> _pay(Supplier supplier) async {
    final result = await showDialog<({int amount, bool fromCash})>(
      context: context,
      builder: (context) => SupplierPaymentDialog(
        name: supplier.name,
        balanceDue: supplier.balanceDue,
      ),
    );
    if (result == null || !mounted) return;
    try {
      final payment = await ref
          .read(suppliersActionsProvider)
          .pay(supplier.id, result.amount, fromCash: result.fromCash);
      if (mounted) {
        _snack(
          context,
          'Paiement de ${formatDA(payment.amount)} enregistré — reste dû '
          '${formatDA(payment.balanceDue)}.',
        );
      }
    } on ApiException catch (error) {
      if (mounted) _snack(context, error.userMessage);
    }
  }
}

/// Paiement À un fournisseur (ou à un confrère) : montant, depuis la caisse
/// ou non. Rend `(amount, fromCash)`.
class SupplierPaymentDialog extends StatefulWidget {
  const SupplierPaymentDialog({
    super.key,
    required this.name,
    required this.balanceDue,
  });

  final String name;
  final int balanceDue;

  @override
  State<SupplierPaymentDialog> createState() => _SupplierPaymentDialogState();
}

class _SupplierPaymentDialogState extends State<SupplierPaymentDialog> {
  late final TextEditingController _amount = TextEditingController(
    text: formatDA(widget.balanceDue, withSymbol: false),
  );
  bool _fromCash = true;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = parseDA(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Montant invalide');
      return;
    }
    if (amount > widget.balanceDue) {
      setState(() => _error = 'Au-delà du reste dû');
      return;
    }
    Navigator.of(context).pop((amount: amount, fromCash: _fromCash));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Payer ${widget.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Reste dû : ${formatDA(widget.balanceDue)}'),
          const SizedBox(height: 8),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Montant',
              suffixText: 'DA',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _fromCash,
            onChanged: (v) => setState(() => _fromCash = v),
            title: const Text('Payé depuis la caisse'),
            subtitle: Text(
              _fromCash
                  ? 'Sortie enregistrée dans votre caisse ouverte (rapport Z).'
                  : 'Virement ou espèces hors tiroir : la caisse n’est pas touchée.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Enregistrer')),
      ],
    );
  }
}

class _SupplierForm extends ConsumerStatefulWidget {
  const _SupplierForm({this.existing});

  final Supplier? existing;

  @override
  ConsumerState<_SupplierForm> createState() => _SupplierFormState();
}

class _SupplierFormState extends ConsumerState<_SupplierForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _phone = TextEditingController(text: widget.existing?.phone ?? '');
  late final _contact = TextEditingController(
    text: widget.existing?.contactName ?? '',
  );
  late final _email = TextEditingController(text: widget.existing?.email ?? '');
  late final _address = TextEditingController(
    text: widget.existing?.address ?? '',
  );
  late final _opening = TextEditingController(
    text: formatDA(widget.existing?.openingBalance ?? 0, withSymbol: false),
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _phone, _contact, _email, _address, _opening]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(suppliersActionsProvider)
          .save(
            id: widget.existing?.id,
            name: _name.text.trim(),
            phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
            contactName: _contact.text.trim().isEmpty
                ? null
                : _contact.text.trim(),
            email: _email.text.trim().isEmpty ? null : _email.text.trim(),
            address: _address.text.trim().isEmpty ? null : _address.text.trim(),
            openingBalance: parseDA(_opening.text) ?? 0,
          );
      if (mounted) Navigator.of(context).pop();
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
    final colors = AmpereColors.of(context);
    Widget field(
      String label,
      TextEditingController controller, {
      TextInputType? keyboard,
      String? suffix,
      String? Function(String?)? validator,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AmpereFieldLabel(label),
          TextFormField(
            controller: controller,
            enabled: !_saving,
            keyboardType: keyboard,
            style: AmpereType.input.copyWith(color: colors.ink),
            decoration: InputDecoration(suffixText: suffix),
            validator: validator,
          ),
        ],
      ),
    );

    return FormPanelFrame(
      formKey: _formKey,
      title: widget.existing == null
          ? 'Nouveau fournisseur'
          : widget.existing!.name,
      saving: _saving,
      error: _error,
      onSubmit: _saving ? null : _submit,
      children: [
        field(
          'Nom',
          _name,
          validator: (v) =>
              (v ?? '').trim().length < 2 ? 'Nom trop court' : null,
        ),
        field('Téléphone', _phone, keyboard: TextInputType.phone),
        field('Contact', _contact),
        field(
          'E-mail',
          _email,
          keyboard: TextInputType.emailAddress,
          validator: (v) {
            final raw = (v ?? '').trim();
            return raw.isEmpty ||
                    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(raw)
                ? null
                : 'E-mail invalide';
          },
        ),
        field('Adresse', _address),
        field(
          'Dette déjà due (reprise)',
          _opening,
          keyboard: const TextInputType.numberWithOptions(decimal: true),
          suffix: 'DA',
          validator: (v) {
            final raw = (v ?? '').trim();
            if (raw.isEmpty) return null;
            final amount = parseDA(raw);
            if (amount == null || amount < 0) return 'Montant invalide';
            final paid = widget.existing?.paidAmount ?? 0;
            return amount < paid
                ? 'Déjà payé ${formatDA(paid)} : reprise trop basse'
                : null;
          },
        ),
        Text(
          'Ce que vous deviez à ce fournisseur avant le logiciel. Les achats '
          's’y ajouteront (feature Achats).',
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
      ],
    );
  }
}
