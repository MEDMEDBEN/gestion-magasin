import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/catalog_controller.dart';
import '../data/catalog_models.dart';

/// Catégorie ou sous-catégorie (ADMIN). Deux niveaux maximum : le parent
/// proposé est toujours une catégorie racine, et une catégorie qui a déjà des
/// sous-catégories ne peut pas descendre d'un niveau (règle serveur).
class CategoryForm extends ConsumerStatefulWidget {
  const CategoryForm({super.key, this.existing, this.initialParentId});

  final ProductCategory? existing;
  final String? initialParentId;

  @override
  ConsumerState<CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends ConsumerState<CategoryForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  String? _parentId;
  late bool _isActive;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _parentId = widget.existing?.parentId ?? widget.initialParentId;
    _isActive = widget.existing?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final existing = widget.existing;
    final values = <String, Object?>{
      'name': _name.text.trim(),
      'parentId': _parentId,
      if (existing != null) 'isActive': _isActive,
    };
    final payload = existing == null
        ? {
            for (final e in values.entries)
              if (e.value != null) e.key: e.value,
          }
        : changedFields({
            'name': existing.name,
            'parentId': existing.parentId,
            'isActive': existing.isActive,
          }, values);
    if (existing != null && payload.isEmpty) {
      Navigator.of(context).pop(existing);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref
          .read(catalogActionsProvider)
          .saveCategory(existing?.id, payload);
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.userMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final categories = ref.watch(categoriesProvider).value ?? const [];
    final existing = widget.existing;
    final hasChildren =
        existing != null && categories.any((c) => c.parentId == existing.id);
    final roots = [
      for (final c in categories)
        if (c.parentId == null &&
            c.id != existing?.id &&
            (c.isActive || c.id == _parentId))
          c,
    ];

    return FormPanelFrame(
      formKey: _formKey,
      title: existing == null ? 'Nouvelle catégorie' : 'Modifier la catégorie',
      submitLabel: existing == null ? 'Créer la catégorie' : 'Enregistrer',
      onSubmit: _submit,
      saving: _saving,
      error: _error,
      children: [
        const AmpereFieldLabel('Nom'),
        TextFormField(
          controller: _name,
          enabled: !_saving,
          autofocus: existing == null,
          maxLength: 80,
          style: AmpereType.input.copyWith(color: colors.ink),
          decoration: const InputDecoration(
            prefixIcon: Icon(LucideIcons.folder, size: 17),
            counterText: '',
          ),
          validator: (v) => (v == null || v.trim().length < 2)
              ? 'Au moins 2 caractères'
              : null,
        ),
        formFieldGap,
        const AmpereFieldLabel('Rangée dans'),
        DropdownButtonFormField<String?>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: _parentId,
          isExpanded: true,
          decoration: InputDecoration(
            prefixIcon: const Icon(LucideIcons.folderTree, size: 17),
            helperText: hasChildren
                ? 'Elle a des sous-catégories : elle reste au premier niveau'
                : 'Deux niveaux : catégorie → sous-catégorie',
          ),
          items: [
            const DropdownMenuItem(
              value: null,
              child: Text('Premier niveau (catégorie)'),
            ),
            for (final root in roots)
              DropdownMenuItem(value: root.id, child: Text(root.name)),
          ],
          onChanged: _saving || hasChildren
              ? null
              : (v) => setState(() => _parentId = v),
        ),
        if (existing != null) ...[
          formFieldGap,
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _isActive,
            onChanged: _saving ? null : (v) => setState(() => _isActive = v),
            title: const Text('Catégorie active'),
            subtitle: const Text(
              'Désactivée : elle n’est plus proposée, ses produits la gardent',
            ),
          ),
        ],
      ],
    );
  }
}
