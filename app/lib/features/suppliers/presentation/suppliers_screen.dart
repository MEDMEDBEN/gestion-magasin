import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/providers.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../application/suppliers_controller.dart';
import '../data/suppliers_models.dart';

/// Droits fournisseurs, MIROIRS des guards serveur (`docs/permissions.md`) :
/// le vendeur n'a AUCUN accès, seul l'admin écrit et paie.
class SupplierRights {
  SupplierRights(AuthUser user)
    : canRead =
          (user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
          user.can('supplier.read'),
      canWrite = user.can('supplier.write'),
      canPay = user.can('supplier.payment.create');

  final bool canRead;
  final bool canWrite;
  final bool canPay;
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
                            onTap: rights.canWrite || rights.canPay
                                ? () => _openActions(s, rights)
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

  Future<void> _openActions(Supplier supplier, SupplierRights rights) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(supplier.name),
              subtitle: Text('Reste dû : ${formatDA(supplier.balanceDue)}'),
            ),
            if (rights.canPay && supplier.balanceDue > 0)
              ListTile(
                leading: const Icon(LucideIcons.banknote, size: 18),
                title: const Text('Enregistrer un paiement'),
                onTap: () => Navigator.of(context).pop('pay'),
              ),
            if (rights.canWrite)
              ListTile(
                leading: const Icon(LucideIcons.pencil, size: 18),
                title: const Text('Modifier la fiche'),
                onTap: () => Navigator.of(context).pop('edit'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'pay') await _pay(supplier);
    if (action == 'edit') await _openForm(supplier);
  }

  Future<void> _openForm(Supplier? existing) =>
      openFormPanel<void>(context, _SupplierForm(existing: existing));

  Future<void> _pay(Supplier supplier) async {
    final paymentId = ref.read(uuidProvider).v7();
    final result = await showDialog<({int amount, bool fromCash})>(
      context: context,
      builder: (context) => _PaymentDialog(supplier: supplier),
    );
    if (result == null || !mounted) return;
    try {
      final payment = await ref
          .read(suppliersActionsProvider)
          .pay(
            supplier.id,
            result.amount,
            fromCash: result.fromCash,
            paymentId: paymentId,
          );
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

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.supplier});

  final Supplier supplier;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  late final TextEditingController _amount = TextEditingController(
    text: formatDA(widget.supplier.balanceDue, withSymbol: false),
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
    if (amount > widget.supplier.balanceDue) {
      setState(() => _error = 'Au-delà du reste dû');
      return;
    }
    Navigator.of(context).pop((amount: amount, fromCash: _fromCash));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Payer ${widget.supplier.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Reste dû : ${formatDA(widget.supplier.balanceDue)}'),
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
    for (final c in [_name, _phone, _contact, _address, _opening]) {
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
