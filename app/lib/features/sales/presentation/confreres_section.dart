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
import '../../../ui/widgets/amount_dialog.dart';
import '../../../ui/widgets/fields_dialog.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../../ui/widgets/search_picker.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../suppliers/application/suppliers_controller.dart';
import '../../suppliers/presentation/suppliers_screen.dart';
import '../application/sales_controller.dart';
import '../data/confrere.dart';
import '../data/sales_api.dart';
import '../data/sales_models.dart';

void _snack(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));

String _errorText(Object error) =>
    error is ApiException ? error.userMessage : 'Action impossible';

/// Confrères (décision MEDMEDBEN 2026-10-08) : admin + vendeur. Vendre (le
/// panier habituel), acheter, échanger ; dette sans plafond des deux côtés.
/// Le versement AU confrère est un paiement fournisseur : admin seul.
class ConfreresSection extends ConsumerWidget {
  const ConfreresSection({
    super.key,
    required this.margin,
    required this.canPayConfreres,
    required this.onSell,
  });

  final double margin;

  /// `POST /payments/supplier` : ADMIN + supplier.payment.create.
  final bool canPayConfreres;

  /// Ouvre la vente avec ce client (le confrère) au panier.
  final ValueChanged<Customer> onSell;

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final values = await askFields(
      context,
      title: 'Nouveau confrère',
      fields: const [
        (key: 'name', label: 'Nom', initial: ''),
        (key: 'phone', label: 'Téléphone (facultatif)', initial: ''),
      ],
    );
    if (values == null || !context.mounted) return;
    try {
      await ref.read(salesApiProvider).createConfrere({
        'id': ref.read(uuidProvider).v7(),
        'name': values['name'],
        if (values['phone']!.isNotEmpty) 'phone': values['phone'],
      });
      ref.invalidate(confreresProvider);
      ref.invalidate(customerSearchProvider);
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  Future<void> _sell(BuildContext context, WidgetRef ref, Confrere c) async {
    try {
      onSell(await ref.read(salesApiProvider).customer(c.id));
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  /// Il me paie : un règlement client ordinaire (caisse ouverte).
  Future<void> _receive(BuildContext context, WidgetRef ref, Confrere c) async {
    final amount = await askAmount(
      context,
      title: 'Règlement de ${c.name}',
      label: 'Espèces reçues',
      confirm: 'Encaisser',
      initial: c.theyOwe > 0 ? c.theyOwe : null,
      help: 'Il me doit : ${formatDA(c.theyOwe)}',
    );
    if (amount == null || amount == 0 || !context.mounted) return;
    try {
      final outcome = await ref
          .read(salesActionsProvider)
          .payCustomer(c.id, amount);
      ref.invalidate(confreresProvider);
      if (context.mounted) {
        _snack(
          context,
          outcome is Queued
              ? 'Règlement enregistré sur cet appareil — en attente de '
                    'synchronisation.'
              : 'Règlement de ${formatDA(amount)} encaissé.',
        );
      }
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  /// Je le paie : paiement fournisseur (admin).
  Future<void> _pay(BuildContext context, WidgetRef ref, Confrere c) async {
    final result = await showDialog<({int amount, bool fromCash})>(
      context: context,
      builder: (_) => SupplierPaymentDialog(name: c.name, balanceDue: c.weOwe),
    );
    if (result == null || !context.mounted) return;
    try {
      await ref
          .read(suppliersActionsProvider)
          .pay(c.supplierId, result.amount, fromCash: result.fromCash);
      ref.invalidate(confreresProvider);
      if (context.mounted) {
        _snack(context, 'Paiement de ${formatDA(result.amount)} enregistré.');
      }
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  Future<void> _deal(
    BuildContext context,
    Confrere c, {
    required bool exchange,
  }) => openFormPanel<void>(
    context,
    ConfrereDealForm(confrere: c, exchange: exchange),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final confreres = ref.watch(confreresProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Vente, achat et échange avec les autres commerçants. '
                  'Dette sans plafond.',
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
              ),
              FilledButton.icon(
                onPressed: () => _create(context, ref),
                icon: const Icon(LucideIcons.plus, size: 17),
                label: const Text('Nouveau confrère'),
              ),
            ],
          ),
        ),
        Expanded(
          child: confreres.when(
            loading: () => const AmpereSkeletonList(rows: 4),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: _errorText(error),
              onRetry: () => ref.invalidate(confreresProvider),
            ),
            data: (items) => items.isEmpty
                ? const ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Aucun confrère',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final c in items)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        c.phone == null
                                            ? c.name
                                            : '${c.name} · ${c.phone}',
                                        style: AmpereType.bodyStrong.copyWith(
                                          color: colors.ink,
                                        ),
                                      ),
                                    ),
                                    AmpereBadge(
                                      label: c.net > 0
                                          ? 'Il me doit ${formatDA(c.net)}'
                                          : c.net < 0
                                          ? 'Je lui dois ${formatDA(-c.net)}'
                                          : 'À jour',
                                      tone: c.net == 0
                                          ? StatusTone.ok
                                          : StatusTone.warn,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Il me doit ${formatDA(c.theyOwe)} · '
                                  'je lui dois ${formatDA(c.weOwe)}',
                                  style: AmpereType.meta.copyWith(
                                    color: colors.ink3,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    TextButton.icon(
                                      onPressed: () => _sell(context, ref, c),
                                      icon: const Icon(
                                        LucideIcons.shoppingCart,
                                        size: 16,
                                      ),
                                      label: const Text('Lui vendre'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () =>
                                          _deal(context, c, exchange: false),
                                      icon: const Icon(
                                        LucideIcons.packagePlus,
                                        size: 16,
                                      ),
                                      label: const Text('Lui acheter'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () =>
                                          _deal(context, c, exchange: true),
                                      icon: const Icon(
                                        LucideIcons.arrowLeftRight,
                                        size: 16,
                                      ),
                                      label: const Text('Échange'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () =>
                                          _receive(context, ref, c),
                                      icon: const Icon(
                                        LucideIcons.banknote,
                                        size: 16,
                                      ),
                                      label: const Text('Il me paie'),
                                    ),
                                    if (canPayConfreres)
                                      TextButton.icon(
                                        onPressed: () => _pay(context, ref, c),
                                        icon: const Icon(
                                          LucideIcons.handCoins,
                                          size: 16,
                                        ),
                                        label: const Text('Je le paie'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// Ligne en cours de saisie : produit, quantité, prix.
class _Line {
  String? productId;
  final quantity = TextEditingController();
  final price = TextEditingController();

  void dispose() {
    quantity.dispose();
    price.dispose();
  }
}

/// Achat à un confrère (« il me donne ») ou échange (« il me donne » + « je
/// lui donne »). Une seule opération serveur : tout passe ou rien.
class ConfrereDealForm extends ConsumerStatefulWidget {
  const ConfrereDealForm({
    super.key,
    required this.confrere,
    required this.exchange,
  });

  final Confrere confrere;
  final bool exchange;

  @override
  ConsumerState<ConfrereDealForm> createState() => _ConfrereDealFormState();
}

class _ConfrereDealFormState extends ConsumerState<ConfrereDealForm> {
  final _formKey = GlobalKey<FormState>();
  // Clés STABLES tant que le formulaire est ouvert : un nouvel essai après
  // coupure ne refait ni l'achat ni la vente (le serveur rend l'existant).
  late final String _receptionKey = ref.read(uuidProvider).v7();
  late final String _saleKey = ref.read(uuidProvider).v7();
  final List<_Line> _receive = [_Line()];
  late final List<_Line> _give = widget.exchange ? [_Line()] : [];
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final l in [..._receive, ..._give]) {
      l.dispose();
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
      final result = await ref.read(salesApiProvider).confrereDeal(
        widget.confrere.id,
        {
          'clientMutationId': _receptionKey,
          'receive': [
            for (final l in _receive)
              {
                'productId': l.productId,
                'receivedQuantity': formatQuantity(
                  parseQuantity(l.quantity.text)!,
                ),
                'unitPriceHt': parseDA(l.price.text),
              },
          ],
          if (_give.isNotEmpty) ...{
            'saleMutationId': _saleKey,
            'give': [
              for (final l in _give)
                {
                  'productId': l.productId,
                  'quantity': formatQuantity(parseQuantity(l.quantity.text)!),
                  if (l.price.text.trim().isNotEmpty) ...{
                    'unitPriceHt': parseDA(l.price.text),
                    'priceEdited': true,
                  },
                },
            ],
          },
        },
      );
      ref.invalidate(confreresProvider);
      ref.invalidate(customerSearchProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      final sale = result['saleNumber'] as String?;
      _snack(
        context,
        'Enregistré : ${result['receptionNumber']}'
        '${sale == null ? '' : ' et $sale'}.',
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
    final products =
        ref.watch(activeProductsProvider).value ?? const <Product>[];
    return FormPanelFrame(
      formKey: _formKey,
      title: widget.exchange
          ? 'Échange avec ${widget.confrere.name}'
          : 'Achat à ${widget.confrere.name}',
      saving: _saving,
      error: _error,
      submitLabel: 'Enregistrer',
      onSubmit: _saving ? null : _submit,
      children: [
        AmpereFieldLabel('Il me donne (entre au magasin)'),
        for (final l in _receive)
          _lineRow(l, _receive, products, colors, priceRequired: true),
        _addButton(_receive),
        if (widget.exchange) ...[
          const Divider(height: 24),
          AmpereFieldLabel('Je lui donne (sort du magasin)'),
          for (final l in _give)
            _lineRow(l, _give, products, colors, priceRequired: false),
          _addButton(_give),
          Text(
            'Prix vide : prix du tarif. Jamais sous le prix d’achat.',
            style: AmpereType.meta.copyWith(color: colors.ink3),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Rien n’est payé ici : les montants vont dans les dettes.',
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
      ],
    );
  }

  Widget _addButton(List<_Line> lines) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: _saving || lines.length >= 200
          ? null
          : () => setState(() => lines.add(_Line())),
      icon: const Icon(LucideIcons.plus, size: 16),
      label: const Text('Ajouter une ligne'),
    ),
  );

  Widget _lineRow(
    _Line line,
    List<_Line> lines,
    List<Product> products,
    AmpereColors colors, {
    required bool priceRequired,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SearchPickerField<Product>(
                  options: products,
                  idOf: (p) => p.id,
                  labelOf: (p) => '${p.name} · ${p.sku}',
                  searchTextOf: (p) => '${p.name} ${p.sku} ${p.barcode}',
                  value: line.productId,
                  hint: 'Produit',
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => line.productId = v),
                  validator: (v) => v == null ? 'Choisissez un produit' : null,
                ),
              ),
              if (lines.length > 1)
                IconButton(
                  tooltip: 'Retirer la ligne',
                  icon: Icon(LucideIcons.trash2, size: 16, color: colors.error),
                  onPressed: _saving
                      ? null
                      : () => setState(() => lines.remove(line..dispose())),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  controller: line.quantity,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Quantité'),
                  validator: (v) {
                    final q = parseQuantity(v ?? '');
                    return q == null || q <= Quantity.zero
                        ? 'Quantité > 0'
                        : null;
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: line.price,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: priceRequired ? 'Prix d’achat HT' : 'Prix HT',
                    suffixText: 'DA',
                  ),
                  validator: (v) {
                    if (!priceRequired && (v ?? '').trim().isEmpty) return null;
                    final p = parseDA(v ?? '');
                    return p == null || p < 0 ? 'Prix invalide' : null;
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
