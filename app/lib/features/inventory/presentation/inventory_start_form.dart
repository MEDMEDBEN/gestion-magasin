import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../application/inventory_controller.dart';
import '../data/inventory_models.dart';

/// Lancement d'un inventaire (spec §22). Le théorique est figé à cet instant :
/// c'est la feuille de comptage. Aucun stock ne bouge avant la validation.
class InventoryStartForm extends ConsumerStatefulWidget {
  const InventoryStartForm({super.key});

  @override
  ConsumerState<InventoryStartForm> createState() => _InventoryStartFormState();
}

class _InventoryStartFormState extends ConsumerState<InventoryStartForm> {
  final _formKey = GlobalKey<FormState>();

  /// Intention stable : tous les essais de CE lancement portent la même clé.
  late final String _intent = 'inventory:${ref.read(uuidProvider).v7()}';
  final _zone = TextEditingController();
  final Set<String> _productIds = {};
  InventoryType _type = InventoryType.full;
  String? _locationId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _zone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final cycle = _type == InventoryType.cycle;
    if (cycle && _productIds.isEmpty) {
      setState(() => _error = 'Choisissez au moins un produit à compter.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final inventory = await ref
          .read(inventoryActionsProvider)
          .start(
            intent: _intent,
            locationId: _locationId!,
            type: _type,
            productIds: cycle ? _productIds.toList() : null,
            zone: _zone.text.trim().isEmpty ? null : _zone.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${inventory.number} lancé — ${inventory.lines.length} produit(s) à compter.',
          ),
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
    final products =
        ref.watch(activeProductsProvider).value ?? const <Product>[];
    // Le stock vit au magasin ou au dépôt ; rien d'autre ne se compte.
    final stockLocations = [
      for (final l in ref.watch(locationsProvider).value ?? const [])
        if (l.isActive && (l.type == 'MAGASIN' || l.type == 'DEPOT')) l,
    ];

    return FormPanelFrame(
      formKey: _formKey,
      title: 'Lancer un inventaire',
      saving: _saving,
      error: _error,
      submitLabel: 'Lancer le comptage',
      onSubmit: _saving ? null : _submit,
      children: [
        const AmpereInlineAlert(
          tone: StatusTone.info,
          icon: LucideIcons.info,
          message:
              'Le stock théorique est figé maintenant. Rien ne bouge tant que '
              'l’administrateur n’a pas validé les écarts.',
        ),
        const SizedBox(height: 16),
        const AmpereFieldLabel('Lieu compté'),
        DropdownButtonFormField<String>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: stockLocations.any((l) => l.id == _locationId)
              ? _locationId
              : null,
          isExpanded: true,
          hint: const Text('Magasin ou dépôt'),
          items: [
            for (final l in stockLocations)
              DropdownMenuItem(value: l.id, child: Text(l.name)),
          ],
          onChanged: _saving ? null : (v) => setState(() => _locationId = v),
          validator: (v) => v == null ? 'Choisissez un lieu' : null,
        ),
        const SizedBox(height: 16),
        const AmpereFieldLabel('Type'),
        SegmentedButton<InventoryType>(
          segments: [
            for (final t in InventoryType.values)
              ButtonSegment(value: t, label: Text(t.label)),
          ],
          selected: {_type},
          onSelectionChanged: _saving
              ? null
              : (s) => setState(() => _type = s.first),
        ),
        const SizedBox(height: 8),
        Text(
          _type == InventoryType.full
              ? 'Complet : tout ce que le lieu porte est compté.'
              : 'Tournant : seuls les produits cochés sont comptés.',
          style: AmpereType.meta.copyWith(color: colors.ink3),
        ),
        if (_type == InventoryType.cycle) ...[
          const SizedBox(height: 16),
          const AmpereFieldLabel('Zone comptée'),
          TextFormField(
            controller: _zone,
            enabled: !_saving,
            maxLength: 100,
            decoration: const InputDecoration(
              hintText: 'Zone A, rayon câbles…',
            ),
          ),
          const AmpereFieldLabel('Produits à compter'),
          for (final p in products)
            CheckboxListTile(
              dense: true,
              value: _productIds.contains(p.id),
              title: Text('${p.name} · ${p.sku}'),
              onChanged: _saving
                  ? null
                  : (checked) => setState(() {
                      if (checked == true) {
                        _productIds.add(p.id);
                      } else {
                        _productIds.remove(p.id);
                      }
                    }),
            ),
        ],
      ],
    );
  }
}
