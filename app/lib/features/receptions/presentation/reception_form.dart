import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/offline_write.dart';
import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../purchases/data/purchases_models.dart';
import '../application/receptions_controller.dart';

/// Une ligne de commande à réceptionner : quantité reçue saisie, reste connu.
class _LineFields {
  _LineFields(this.line)
    : received = TextEditingController(
        text: formatQuantity(line.remainingQuantity),
      );

  final PurchaseLine line;
  final TextEditingController received;

  void dispose() => received.dispose();
}

/// Réception d'une commande confirmée : le magasinier saisit ce qui est
/// RÉELLEMENT arrivé, ligne par ligne. Le serveur refuse toute quantité
/// supérieure au reste à recevoir et fait avancer la commande.
class ReceptionForm extends ConsumerStatefulWidget {
  const ReceptionForm({super.key, required this.order});

  final PurchaseOrder order;

  @override
  ConsumerState<ReceptionForm> createState() => _ReceptionFormState();
}

class _ReceptionFormState extends ConsumerState<ReceptionForm> {
  final _formKey = GlobalKey<FormState>();

  /// Intention stable : tous les essais de CETTE réception portent la même clé.
  late final String _intent = 'reception:${ref.read(uuidProvider).v7()}';
  late final List<_LineFields> _lines = [
    for (final l in widget.order.lines)
      if (l.remainingQuantity > Quantity.zero) _LineFields(l),
  ];
  String? _locationId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  /// Ce que la réception ajoutera à la dette, hors TVA (le serveur fait foi).
  int get _estimateHt {
    var total = 0;
    for (final l in _lines) {
      final q = parseQuantity(l.received.text);
      if (q == null) continue;
      total += (q * Quantity.fromInt(l.line.unitPriceHt))
          .round()
          .toBigInt()
          .toInt();
    }
    return total;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final lines = [
      for (final l in _lines)
        if ((parseQuantity(l.received.text) ?? Quantity.zero) > Quantity.zero)
          (
            productId: l.line.productId,
            purchaseLineId: l.line.id,
            receivedQuantity: parseQuantity(l.received.text)!,
            unitPriceHt: l.line.unitPriceHt,
          ),
    ];
    if (lines.isEmpty) {
      setState(() => _error = 'Saisissez au moins une quantité reçue.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final outcome = await ref
          .read(receptionsActionsProvider)
          .receive(
            intent: _intent,
            purchaseOrderId: widget.order.id,
            supplierId: widget.order.supplierId,
            locationId: _locationId!,
            lines: lines,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(switch (outcome) {
            Applied(value: final reception) =>
              '${reception.number} : marchandise entrée en stock — '
                  '${formatDA(reception.totalTtc)} TTC ajoutés à la dette.',
            // Rien n'est encore entré : le serveur jugera à la synchro.
            Queued() =>
              'Réception enregistrée sur cet appareil — en attente de '
                  'synchronisation (pas encore en stock).',
          }),
        ),
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
    // Le stock vit au magasin ou au dépôt ; les positions ne portent pas de stock.
    final stockLocations = [
      for (final l in ref.watch(locationsProvider).value ?? const [])
        if (l.isActive && (l.type == 'MAGASIN' || l.type == 'DEPOT')) l,
    ];

    return FormPanelFrame(
      formKey: _formKey,
      title: 'Réceptionner ${widget.order.number}',
      saving: _saving,
      error: _error,
      submitLabel: 'Enregistrer la réception',
      onSubmit: _saving ? null : _submit,
      children: [
        const AmpereInlineAlert(
          tone: StatusTone.info,
          icon: LucideIcons.info,
          message:
              'Saisissez ce qui est RÉELLEMENT arrivé. Le stock et la dette '
              'fournisseur n’augmentent que de ces quantités ; une livraison '
              'supérieure au reste à recevoir est refusée.',
        ),
        const SizedBox(height: 16),
        const AmpereFieldLabel('Emplacement de réception'),
        DropdownButtonFormField<String>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: stockLocations.any((l) => l.id == _locationId)
              ? _locationId
              : null,
          isExpanded: true,
          hint: const Text('Où la marchandise entre-t-elle ?'),
          items: [
            for (final l in stockLocations)
              DropdownMenuItem(value: l.id, child: Text(l.name)),
          ],
          onChanged: _saving ? null : (v) => setState(() => _locationId = v),
          validator: (v) => v == null ? 'Choisissez un emplacement' : null,
        ),
        const SizedBox(height: 16),
        for (final fields in _lines) _lineRow(fields, products, colors),
        const Divider(height: 24),
        Text(
          'Montant reçu estimé : ${formatDA(_estimateHt)} HT',
          style: AmpereType.bodyStrong.copyWith(color: colors.ink),
        ),
        Text(
          'Le prix d’achat de la commande est repris tel quel ; il met à jour '
          'le coût du produit.',
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
      ],
    );
  }

  Widget _lineRow(
    _LineFields fields,
    Map<String, Product> products,
    AmpereColors colors,
  ) {
    final line = fields.line;
    final product = products[line.productId];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AmpereFieldLabel(product?.name ?? 'Produit'),
          TextFormField(
            controller: fields.received,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Quantité reçue',
              helperText:
                  'Commandé ${formatQuantity(line.orderedQuantity)} · '
                  'reste ${formatQuantity(line.remainingQuantity)} · '
                  '${formatDA(line.unitPriceHt)} HT l’unité',
            ),
            onChanged: (_) => setState(() {}),
            validator: (v) {
              final q = parseQuantity(v ?? '');
              if (q == null || q < Quantity.zero) return 'Quantité invalide';
              if (q.scale > quantityScale) return '3 décimales au maximum';
              // Miroir du serveur : la surlivraison est refusée.
              if (q > line.remainingQuantity) {
                return 'Au plus ${formatQuantity(line.remainingQuantity)}';
              }
              return null;
            },
          ),
        ],
      ),
    );
  }
}
