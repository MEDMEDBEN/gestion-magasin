import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../auth/data/auth_models.dart';
import '../../auth/application/auth_controller.dart';
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
import 'invoice_scan.dart';

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
    // Toutes les lignes : un surplus peut arriver sur une ligne déjà soldée.
    for (final l in widget.order.lines) _LineFields(l),
  ];
  String? _locationId;
  bool _saving = false;
  String? _error;

  /// Payé au fournisseur à la livraison (2026-11-15) — ADMIN qui paie.
  final _paid = TextEditingController();
  bool _paidFromCash = false;

  bool get _canPay => switch (ref.read(authControllerProvider).value) {
    AuthSignedIn(:final user) =>
      user.hasRole('ADMIN') && user.can('supplier.payment.create'),
    _ => false,
  };

  int get _paidAmount => parseDA(_paid.text) ?? 0;

  @override
  void dispose() {
    _paid.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  /// Photo de la facture de livraison → quantités REÇUES proposées (P2 n°24),
  /// pour les produits de CETTE commande seulement ; le reste est listé. Rien
  /// n'est enregistré avant « Réceptionner ».
  Future<void> _fromInvoice() async {
    final scanned = await scanInvoice(context, ref);
    if (scanned == null || !mounted) return;
    final applied = <ScannedLine>[];
    final ignored = <ScannedLine>[];
    setState(() {
      for (final l in scanned) {
        final fields = _lines
            .where((f) => f.line.productId == l.productId)
            .firstOrNull;
        final quantity = l.quantity;
        if (fields == null || quantity == null) {
          ignored.add(l);
          continue;
        }
        fields.received.text = formatQuantity(quantity);
        applied.add(l);
      }
    });
    await showScanSummary(context, applied: applied, ignored: ignored);
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
            paidAmount: _canPay ? _paidAmount : 0,
            paidFromCash: _paidFromCash,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(switch (outcome) {
            Applied(value: final reception) =>
              _paidAmount > 0
                  ? '${reception.number} : marchandise en stock — payé '
                        '${formatDA(_paidAmount)}, reste '
                        '${formatDA((reception.totalTtc - _paidAmount).clamp(0, reception.totalTtc))} '
                        'à la dette.'
                  : '${reception.number} : marchandise entrée en stock — '
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
              'fournisseur n’augmentent que de ces quantités (une livraison '
              'plus grande que prévue est acceptée).',
        ),
        // P2 n°24 : quantités proposées depuis une photo de la facture.
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _saving ? null : _fromInvoice,
            icon: const Icon(LucideIcons.scanText, size: 16),
            label: const Text('Lire la facture (photo)'),
          ),
        ),
        const SizedBox(height: 8),
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
        if (_canPay) ...[const SizedBox(height: 16), _paymentSection(colors)],
      ],
    );
  }

  /// Ce qu'on donne au fournisseur à la livraison ; le reste devient sa dette,
  /// réglée ensuite par « Versement » sur sa fiche.
  Widget _paymentSection(AmpereColors colors) {
    final total = _estimateHt;
    final paid = _paidAmount;
    final rest = (total - paid).clamp(0, total);
    void setPaid(int amount) => setState(
      () => _paid.text = amount == 0 ? '' : formatDA(amount, withSymbol: false),
    );
    // Material (pas un simple fond) : la case à cocher garde son effet.
    return Material(
      color: colors.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(LucideIcons.handCoins, size: 18, color: colors.accent),
                const SizedBox(width: 8),
                Text(
                  'Paiement au fournisseur',
                  style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => setPaid(0),
                    child: const Text('Rien payé'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving || total == 0
                        ? null
                        : () => setPaid(total),
                    child: Text('Tout (${formatDA(total)})'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: const ValueKey('champ-paye-fournisseur'),
              controller: _paid,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Montant donné au fournisseur',
                suffixText: 'DA',
              ),
              onChanged: (_) => setState(() {}),
              validator: (v) {
                final raw = v?.trim() ?? '';
                if (raw.isEmpty) return null;
                final amount = parseDA(raw);
                if (amount == null || amount < 0) return 'Montant invalide';
                return amount > total
                    ? 'Au plus ${formatDA(total)} (le reçu de cette livraison)'
                    : null;
              },
            ),
            CheckboxListTile(
              value: _paidFromCash,
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: _saving
                  ? null
                  : (v) => setState(() => _paidFromCash = v ?? false),
              title: const Text('Sorti de la caisse du magasin'),
              subtitle: const Text('Sinon : hors caisse (virement, poche…)'),
            ),
            const SizedBox(height: 4),
            Text(
              paid == 0
                  ? 'Tout passe en dette : ${formatDA(total)}'
                  : rest == 0
                  ? 'Payé en entier — aucune dette'
                  : 'Reste en dette : ${formatDA(rest)}',
              style: AmpereType.bodyStrong.copyWith(
                color: rest == 0 ? colors.ok : colors.warn,
              ),
            ),
          ],
        ),
      ),
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
              // Surlivraison acceptée (2026-11-07) : on saisit ce qui est arrivé.
              return null;
            },
          ),
        ],
      ),
    );
  }
}
