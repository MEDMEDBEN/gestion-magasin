import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/application/catalog_controller.dart';
import '../application/sales_controller.dart';
import '../data/sales_models.dart';

/// Fiche client complète (spec §10, P1 bis n°21e) : création et modification.
/// Tarif et plafond de crédit sont des conditions COMMERCIALES : affichés et
/// envoyés seulement pour qui a `price.manage` (ADMIN) — le serveur refuse
/// sinon. Sans plafond, un client n'a pas de crédit (vente à crédit refusée).
class CustomerForm extends ConsumerStatefulWidget {
  const CustomerForm({
    this.existing,
    required this.canManageTerms,
    this.canChangeActive = false,
    super.key,
  });

  final Customer? existing;
  final bool canManageTerms;

  /// Retirer / réactiver un client : ADMIN seul (le serveur refuse sinon).
  final bool canChangeActive;

  @override
  ConsumerState<CustomerForm> createState() => _CustomerFormState();
}

class _CustomerFormState extends ConsumerState<CustomerForm> {
  final _formKey = GlobalKey<FormState>();
  late final Customer? _c = widget.existing;
  late final _name = TextEditingController(text: _c?.name ?? '');
  late final _phone = TextEditingController(text: _c?.phone ?? '');
  late final _email = TextEditingController(text: _c?.email ?? '');
  late final _address = TextEditingController(text: _c?.address ?? '');
  late final _notes = TextEditingController(text: _c?.notes ?? '');
  late final _limit = TextEditingController(
    text: formatDA(_c?.creditLimit ?? 0, withSymbol: false),
  );
  late String? _tierId = _c?.priceTierId;
  late bool _active = _c?.isActive ?? true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _address, _notes, _limit]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _text(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(salesActionsProvider).saveCustomer(_c?.id, {
        'name': _name.text.trim(),
        'phone': _text(_phone),
        'email': _text(_email),
        'address': _text(_address),
        'notes': _text(_notes),
        if (_c != null && widget.canChangeActive) 'isActive': _active,
        // Envoyés seulement s'ils changent : un tarif depuis désactivé ne
        // bloque pas la modification du reste de la fiche.
        if (widget.canManageTerms && (_c == null || _tierId != _c.priceTierId))
          'priceTierId': _tierId,
        if (widget.canManageTerms &&
            (_c == null || (parseDA(_limit.text) ?? 0) != _c.creditLimit))
          'creditLimit': parseDA(_limit.text) ?? 0,
      });
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
      int maxLines = 1,
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
            maxLines: maxLines,
            style: AmpereType.input.copyWith(color: colors.ink),
            decoration: InputDecoration(suffixText: suffix),
            validator: validator,
          ),
        ],
      ),
    );
    final tiers = widget.canManageTerms
        ? ref.watch(priceTiersProvider).value ?? const []
        : const [];

    return FormPanelFrame(
      formKey: _formKey,
      title: _c == null ? 'Nouveau client' : _c.name,
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
        field('Notes', _notes, maxLines: 3),
        if (widget.canManageTerms) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AmpereFieldLabel('Tarif'),
                DropdownButtonFormField<String?>(
                  initialValue: tiers.any((t) => t.id == _tierId)
                      ? _tierId
                      : null,
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Tarif par défaut'),
                    ),
                    for (final t in tiers)
                      DropdownMenuItem(value: t.id, child: Text(t.name)),
                  ],
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _tierId = v),
                ),
              ],
            ),
          ),
          field(
            'Plafond de crédit',
            _limit,
            keyboard: const TextInputType.numberWithOptions(decimal: true),
            suffix: 'DA',
            validator: (v) {
              final raw = (v ?? '').trim();
              if (raw.isEmpty) return null;
              final amount = parseDA(raw);
              return amount == null || amount < 0 ? 'Montant invalide' : null;
            },
          ),
          Text(
            'Dette maximale autorisée pour ce client. 0 : aucune vente à '
            'crédit.',
            style: AmpereType.meta.copyWith(color: colors.ink3),
          ),
        ],
        if (_c != null && widget.canChangeActive)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Client actif'),
            value: _active,
            onChanged: _saving ? null : (v) => setState(() => _active = v),
          ),
      ],
    );
  }
}
