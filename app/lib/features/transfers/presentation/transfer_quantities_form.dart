import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/transfers_controller.dart';
import '../data/transfers_models.dart';

/// Les deux comptages d'un transfert : ce que le dépôt PRÉPARE, et ce que le
/// magasin REÇOIT. Même geste (une quantité par ligne, bornée par l'étape
/// précédente), donc un seul écran.
enum TransferCountKind {
  prepare(
    title: 'Préparer',
    submit: 'Enregistrer la préparation',
    hint:
        'Saisissez ce que vous avez réellement trouvé. Une préparation '
        'partielle est normale ; rien ne quitte le dépôt avant l’expédition.',
  ),
  receive(
    title: 'Réceptionner',
    submit: 'Enregistrer la réception',
    hint:
        'Saisissez ce qui est réellement arrivé. Le manquant retourne au '
        'dépôt pour y être constaté (perte, casse).',
  );

  const TransferCountKind({
    required this.title,
    required this.submit,
    required this.hint,
  });

  final String title;
  final String submit;
  final String hint;
}

class _LineFields {
  _LineFields(this.line, this.maximum, Quantity initial)
    : quantity = TextEditingController(text: formatQuantity(initial));

  final TransferLine line;

  /// Plafond imposé par le serveur : le demandé (préparation) ou l'expédié
  /// (réception).
  final Quantity maximum;
  final TextEditingController quantity;

  void dispose() => quantity.dispose();
}

class TransferQuantitiesForm extends ConsumerStatefulWidget {
  const TransferQuantitiesForm({
    super.key,
    required this.transfer,
    required this.kind,
  });

  final Transfer transfer;
  final TransferCountKind kind;

  @override
  ConsumerState<TransferQuantitiesForm> createState() =>
      _TransferQuantitiesFormState();
}

class _TransferQuantitiesFormState
    extends ConsumerState<TransferQuantitiesForm> {
  final _formKey = GlobalKey<FormState>();

  /// À la réception, seules les lignes réellement expédiées se comptent.
  late final List<_LineFields> _lines = [
    for (final l in widget.transfer.lines)
      if (_isPrepare || l.shippedQuantity > Quantity.zero)
        _LineFields(l, _ceiling(l), _initial(l)),
  ];
  bool _saving = false;
  String? _error;

  bool get _isPrepare => widget.kind == TransferCountKind.prepare;

  /// Plafond du serveur : le demandé (préparation), l'expédié (réception).
  Quantity _ceiling(TransferLine line) =>
      _isPrepare ? line.requestedQuantity : line.shippedQuantity;

  /// Valeur proposée : la préparation déjà saisie quand on la reprend, sinon
  /// tout ce qui est attendu à cette étape.
  Quantity _initial(TransferLine line) {
    final resumed =
        _isPrepare &&
        (widget.transfer.status == TransferStatus.preparing ||
            widget.transfer.status == TransferStatus.prepared);
    return resumed ? line.preparedQuantity : _ceiling(line);
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _submit({bool done = true}) async {
    if (!_formKey.currentState!.validate()) return;
    final quantities = {
      for (final l in _lines)
        l.line.productId: parseQuantity(l.quantity.text)!,
    };
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final actions = ref.read(transfersActionsProvider);
      final updated = _isPrepare
          ? await actions.prepare(widget.transfer.id, quantities, done: done)
          : await actions.receive(widget.transfer.id, quantities);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${updated.number} : ${updated.status.label}.')),
      );
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
    final products = {
      for (final p
          in ref.watch(activeProductsProvider).value ?? const <Product>[])
        p.id: p,
    };

    return FormPanelFrame(
      formKey: _formKey,
      title: '${widget.kind.title} ${widget.transfer.number}',
      saving: _saving,
      error: _error,
      submitLabel: widget.kind.submit,
      onSubmit: _saving ? null : _submit,
      children: [
        AmpereInlineAlert(
          tone: StatusTone.info,
          icon: LucideIcons.info,
          message: widget.kind.hint,
        ),
        const SizedBox(height: 16),
        for (final fields in _lines) _lineRow(fields, products, colors),
        if (_isPrepare) ...[
          const Divider(height: 24),
          Text(
            'Préparation en plusieurs fois : enregistrez-la « en cours », elle '
            'vous attendra. Elle ne s’expédie qu’une fois terminée.',
            style: AmpereType.meta.copyWith(color: colors.ink3),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _saving ? null : () => _submit(done: false),
              icon: const Icon(LucideIcons.save, size: 16),
              label: const Text('Enregistrer en cours'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _lineRow(
    _LineFields fields,
    Map<String, Product> products,
    AmpereColors colors,
  ) {
    final product = products[fields.line.productId];
    final isPrepare = _isPrepare;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AmpereFieldLabel(product?.name ?? 'Produit'),
          TextFormField(
            controller: fields.quantity,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: isPrepare
                  ? 'Quantité préparée'
                  : 'Quantité reçue au magasin',
              helperText: isPrepare
                  ? 'Demandé ${formatQuantity(fields.line.requestedQuantity)}'
                  : 'Expédié ${formatQuantity(fields.line.shippedQuantity)}',
            ),
            onChanged: (_) => setState(() {}),
            validator: (v) {
              final q = parseQuantity(v ?? '');
              if (q == null || q < Quantity.zero) return 'Quantité invalide';
              if (q.scale > quantityScale) return '3 décimales au maximum';
              // Miroir du serveur : jamais plus que l'étape précédente.
              if (q > fields.maximum) {
                return 'Au plus ${formatQuantity(fields.maximum)}';
              }
              return null;
            },
          ),
        ],
      ),
    );
  }
}
