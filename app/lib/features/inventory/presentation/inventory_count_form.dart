import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/quantity.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/inventory_controller.dart';
import '../data/inventory_models.dart';

/// Ajustement du stock par l'admin (seule étape qui le touche), après
/// confirmation. Rend `true` si le stock a été ajusté.
Future<bool> adjustInventory(
  BuildContext context,
  WidgetRef ref,
  Inventory inventory,
) async {
  final gaps = inventory.gaps.length;
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Ajuster le stock (${inventory.number}) ?'),
      content: Text(
        gaps == 0
            ? 'Aucun écart : le stock ne bougera pas, l’inventaire sera clos.'
            : '$gaps produit(s) en écart : le stock sera corrigé d’autant. '
                  'Ensuite, l’inventaire ne se modifie plus.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Plus tard'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Ajuster le stock'),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return false;
  try {
    final updated = await ref
        .read(inventoryActionsProvider)
        .validate(inventory.id);
    if (context.mounted) _snack(context, '${updated.number} : stock ajusté.');
    return true;
  } on ApiException catch (error) {
    if (error.statusCode == 409) ref.invalidate(inventoriesProvider);
    if (context.mounted) _snack(context, error.userMessage);
    return false;
  }
}

/// Suppression d'un inventaire pas encore ajusté, après confirmation.
Future<bool> deleteInventory(
  BuildContext context,
  WidgetRef ref,
  Inventory inventory,
) async {
  final sure = await showAmpereConfirmDialog(
    context,
    title: 'Supprimer ${inventory.number} ?',
    body: 'Le comptage saisi sera perdu. Le stock ne bouge pas.',
    confirmLabel: 'Supprimer',
  );
  if (!sure || !context.mounted) return false;
  try {
    await ref.read(inventoryActionsProvider).remove(inventory.id);
    if (context.mounted) _snack(context, '${inventory.number} supprimé.');
    return true;
  } on ApiException catch (error) {
    if (context.mounted) _snack(context, error.userMessage);
    return false;
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Saisie du comptage physique (spec §22), en un seul écran : on cherche le
/// produit, on tape ce qu'on compte, on enregistre ou on termine.
///
/// Le théorique n'est PAS pré-rempli : afficher la réponse attendue est le
/// meilleur moyen d'obtenir un comptage complaisant. Il est montré une fois le
/// produit compté.
class InventoryCountForm extends ConsumerStatefulWidget {
  const InventoryCountForm({
    super.key,
    required this.inventory,
    this.canAdjust = false,
    this.canDelete = false,
  });

  final Inventory inventory;

  /// Admin : « Terminer » propose d'ajuster le stock tout de suite.
  final bool canAdjust;
  final bool canDelete;

  @override
  ConsumerState<InventoryCountForm> createState() => _InventoryCountFormState();
}

class _InventoryCountFormState extends ConsumerState<InventoryCountForm> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _counted = {
    for (final l in widget.inventory.lines)
      l.productId: TextEditingController(
        text: l.countedQuantity == null
            ? ''
            : formatQuantity(l.countedQuantity!),
      ),
  };
  String _filter = '';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _counted.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit({bool done = false}) async {
    if (!_formKey.currentState!.validate()) return;
    final counted = <String, Quantity>{
      for (final e in _counted.entries)
        if (e.value.text.trim().isNotEmpty) e.key: parseQuantity(e.value.text)!,
    };
    if (counted.isEmpty) {
      setState(() => _error = 'Saisissez au moins une quantité.');
      return;
    }
    if (done && counted.length < _counted.length) {
      setState(
        () => _error =
            '${_counted.length - counted.length} produit(s) sans quantité : '
            'complétez-les, ou « Enregistrer » pour finir plus tard.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await ref
          .read(inventoryActionsProvider)
          .count(widget.inventory.id, counted, done: done);
      if (!mounted) return;
      if (done && widget.canAdjust) {
        await adjustInventory(context, ref, updated);
        if (!mounted) return;
      } else {
        final gaps = updated.gaps.length;
        _snack(
          context,
          !done
              ? '${updated.number} enregistré : ${updated.countedCount} sur '
                    '${updated.lines.length} compté(s).'
              : gaps == 0
              ? '${updated.number} terminé — aucun écart.'
              : '${updated.number} terminé — $gaps écart(s), l’administrateur '
                    'ajustera le stock.',
        );
      }
      Navigator.of(context).pop();
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          // Le comptage reste EN LIGNE (docs/context.md §9) : le serveur seul
          // sait à quoi comparer les quantités.
          _error = error.isOffline
              ? 'Comptage impossible hors ligne : il se compare au stock du '
                    'serveur. Reconnectez-vous pour l’enregistrer.'
              : error.userMessage;
          _saving = false;
        });
      }
    }
  }

  Future<void> _delete() async {
    if (await deleteInventory(context, ref, widget.inventory) && mounted) {
      Navigator.of(context).pop();
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
    final filled = _counted.values.where((c) => c.text.trim().isNotEmpty);
    final shown = [
      for (final line in widget.inventory.lines)
        if (_matches(products[line.productId])) line,
    ];

    return FormPanelFrame(
      formKey: _formKey,
      title: 'Comptage ${widget.inventory.number}',
      saving: _saving,
      error: _error,
      submitLabel: widget.canAdjust ? 'Terminer et ajuster' : 'Terminer',
      onSubmit: _saving ? null : () => _submit(done: true),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${filled.length} sur ${_counted.length} produit(s) comptés',
                style: AmpereType.bodyStrong.copyWith(color: colors.ink),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _saving ? null : () => _submit(),
              icon: const Icon(LucideIcons.save, size: 16),
              label: const Text('Enregistrer'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Tapez ce que vous comptez. « Enregistrer » pour continuer plus tard ; '
          'le stock ne bouge qu’à l’ajustement.',
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
        const SizedBox(height: 12),
        if (_counted.length > 5) ...[
          TextField(
            autocorrect: false,
            decoration: const InputDecoration(
              prefixIcon: Icon(LucideIcons.search, size: 17),
              hintText: 'Chercher : nom, référence, code-barres',
            ),
            onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
          ),
          const SizedBox(height: 12),
        ],
        for (final line in shown)
          _lineRow(line, products[line.productId], colors),
        if (shown.isEmpty)
          Text(
            'Aucun produit de cet inventaire ne correspond.',
            style: AmpereType.meta.copyWith(color: colors.ink3),
          ),
        if (widget.canDelete) ...[
          const Divider(height: 32),
          Align(
            alignment: Alignment.centerLeft,
            child: AmpereDangerButton(
              icon: LucideIcons.trash2,
              label: 'Supprimer l’inventaire',
              onPressed: _saving ? null : _delete,
            ),
          ),
        ],
      ],
    );
  }

  bool _matches(Product? product) {
    if (_filter.isEmpty) return true;
    if (product == null) return false;
    return '${product.name} ${product.sku} ${product.barcode}'
        .toLowerCase()
        .contains(_filter);
  }

  Widget _lineRow(InventoryLine line, Product? product, AmpereColors colors) {
    // Le théorique n'est révélé qu'APRÈS un premier comptage : le compteur ne
    // doit pas se contenter de recopier l'attendu.
    final hint = line.countedQuantity == null
        ? product?.sku ?? ''
        : 'théorique ${formatQuantity(line.theoreticalQuantity)} · écart '
              '${formatQuantity(line.difference)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(product?.name ?? 'Produit', style: AmpereType.body),
                Text(
                  hint,
                  style: AmpereType.meta.copyWith(
                    color: line.state == InventoryLineState.gap
                        ? colors.warn
                        : colors.ink3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 120,
            child: TextFormField(
              controller: _counted[line.productId],
              enabled: !_saving,
              textAlign: TextAlign.end,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                hintText: 'Compté',
                suffixText: product?.unit.short,
              ),
              onChanged: (_) => setState(() {}),
              validator: (v) {
                final text = (v ?? '').trim();
                if (text.isEmpty) return null;
                final q = parseQuantity(text);
                if (q == null || q < Quantity.zero) return 'Invalide';
                if (q.scale > quantityScale) return '3 décimales max';
                return null;
              },
            ),
          ),
        ],
      ),
    );
  }
}
