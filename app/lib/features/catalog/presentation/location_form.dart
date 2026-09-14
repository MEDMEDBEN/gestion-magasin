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

/// Emplacement du dépôt (ADMIN + MAGASINIER) : Zone → Rayon → Étagère →
/// Position (spec §5). À la création, code et nom vides sont dérivés par le
/// serveur (`A-02-04-03`). En modification, le code n'est JAMAIS recalculé :
/// il peut être imprimé sur une étiquette.
class LocationForm extends ConsumerStatefulWidget {
  const LocationForm({super.key, this.existing});

  final StorageLocation? existing;

  @override
  ConsumerState<LocationForm> createState() => _LocationFormState();
}

class _LocationFormState extends ConsumerState<LocationForm> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields;
  late bool _isActive;
  bool _saving = false;
  String? _error;

  static const _labels = {
    'zone': 'Zone',
    'aisle': 'Rayon',
    'shelf': 'Étagère',
    'position': 'Position',
  };

  @override
  void initState() {
    super.initState();
    final l = widget.existing;
    _fields = {
      'zone': TextEditingController(text: l?.zone ?? ''),
      'aisle': TextEditingController(text: l?.aisle ?? ''),
      'shelf': TextEditingController(text: l?.shelf ?? ''),
      'position': TextEditingController(text: l?.position ?? ''),
      'code': TextEditingController(text: l?.code ?? ''),
      'name': TextEditingController(text: l?.name ?? ''),
    };
    _isActive = l?.isActive ?? true;
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _value(String key) {
    final text = _fields[key]!.text.trim();
    return text.isEmpty ? null : text;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final existing = widget.existing;
    final Map<String, Object?> payload;
    if (existing == null) {
      payload = {
        for (final key in _fields.keys)
          if (_value(key) != null)
            key: key == 'code' ? _value(key)!.toUpperCase() : _value(key),
      };
    } else {
      payload = changedFields(
        {
          'zone': existing.zone,
          'aisle': existing.aisle,
          'shelf': existing.shelf,
          'position': existing.position,
          'code': existing.code,
          'name': existing.name,
          'isActive': existing.isActive,
        },
        {
          for (final key in _labels.keys) key: _value(key),
          // Code et nom ne se retirent pas : vidés, ils restent inchangés.
          'code': _value('code')?.toUpperCase() ?? existing.code,
          'name': _value('name') ?? existing.name,
          'isActive': _isActive,
        },
      );
      if (payload.isEmpty) {
        Navigator.of(context).pop(existing);
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref
          .read(catalogActionsProvider)
          .saveLocation(existing?.id, payload);
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
    final existing = widget.existing;
    final inputStyle = AmpereType.input.copyWith(color: colors.ink);

    Widget part(String key) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AmpereFieldLabel(_labels[key]!),
          TextFormField(
            controller: _fields[key],
            enabled: !_saving,
            maxLength: 20,
            style: inputStyle,
            decoration: const InputDecoration(counterText: ''),
          ),
        ],
      ),
    );

    return FormPanelFrame(
      formKey: _formKey,
      title: existing == null ? 'Nouvel emplacement' : 'Modifier l’emplacement',
      submitLabel: existing == null ? 'Créer l’emplacement' : 'Enregistrer',
      onSubmit: _submit,
      saving: _saving,
      error: _error,
      children: [
        Row(children: [part('zone'), const SizedBox(width: 12), part('aisle')]),
        formFieldGap,
        Row(
          children: [
            part('shelf'),
            const SizedBox(width: 12),
            part('position'),
          ],
        ),
        formFieldGap,
        const AmpereFieldLabel('Code'),
        TextFormField(
          controller: _fields['code'],
          enabled: !_saving,
          maxLength: 40,
          autocorrect: false,
          style: AmpereType.mono.copyWith(color: colors.ink, fontSize: 15),
          decoration: InputDecoration(
            prefixIcon: const Icon(LucideIcons.hash, size: 17),
            counterText: '',
            helperText: existing == null
                ? 'Vide : dérivé de la structure, ex. A-02-04-03'
                : 'Changer le code rend ses étiquettes imprimées obsolètes',
          ),
          validator: (v) {
            final raw = v?.trim() ?? '';
            if (raw.isEmpty) {
              return existing == null && _value('zone') == null
                  ? 'Saisissez au moins la zone, ou un code'
                  : null;
            }
            return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(raw)
                ? null
                : 'Lettres, chiffres, « . », « _ », « - »';
          },
        ),
        formFieldGap,
        const AmpereFieldLabel('Nom'),
        TextFormField(
          controller: _fields['name'],
          enabled: !_saving,
          maxLength: 100,
          style: inputStyle,
          decoration: InputDecoration(
            prefixIcon: const Icon(LucideIcons.mapPin, size: 17),
            counterText: '',
            helperText: existing == null
                ? 'Vide : « Zone A · Rayon 02 · … »'
                : null,
          ),
        ),
        if (existing != null) ...[
          formFieldGap,
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _isActive,
            onChanged: _saving ? null : (v) => setState(() => _isActive = v),
            title: const Text('Emplacement actif'),
            subtitle: const Text('Désactivé : on n’y range plus de produit'),
          ),
        ],
      ],
    );
  }
}
