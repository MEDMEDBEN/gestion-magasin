import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/planning_controller.dart';
import '../data/planning_models.dart';

/// Création ou modification d'une tâche par l'ADMIN (spec §23 : « l'admin crée
/// un planning de saisie/révision par semaine »).
class PlanningTaskForm extends ConsumerStatefulWidget {
  const PlanningTaskForm({super.key, this.existing});

  final PlanningTask? existing;

  @override
  ConsumerState<PlanningTaskForm> createState() => _PlanningTaskFormState();
}

class _PlanningTaskFormState extends ConsumerState<PlanningTaskForm> {
  final _formKey = GlobalKey<FormState>();
  late final String _id = ref.read(uuidProvider).v7();
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _zone = TextEditingController(text: widget.existing?.zone);
  late final _description = TextEditingController(
    text: widget.existing?.description,
  );
  late PlanningTaskType _type = widget.existing?.type ?? PlanningTaskType.count;
  late String? _assignedToId = widget.existing?.assignedToId;
  late DateTime _scheduledFor = _day(widget.existing?.scheduledFor);
  late DateTime _dueDate = _day(
    widget.existing?.dueDate,
    fallback: DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 2)),
  );
  bool _saving = false;
  String? _error;

  /// `AAAA-MM-JJ` → jour LOCAL à minuit (pas d'UTC : c'est un jour civil).
  static DateTime _day(String? iso, {DateTime? fallback}) {
    if (iso == null) return fallback ?? DateUtils.dateOnly(DateTime.now());
    final p = iso.split('-').map(int.parse).toList();
    return DateTime(p[0], p[1], p[2]);
  }

  @override
  void dispose() {
    _title.dispose();
    _zone.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pick({required bool due}) async {
    final today = DateUtils.dateOnly(DateTime.now());
    // Une échéance n'est jamais REPOUSSÉE dans le passé (le serveur la
    // refuse) ; le jour prévu d'une tâche existante peut l'être.
    final first = due ? today : today.subtract(const Duration(days: 365));
    final current = due ? _dueDate : _scheduledFor;
    final picked = await showDatePicker(
      context: context,
      helpText: due ? 'Échéance' : 'Jour prévu',
      // Une tâche EN RETARD porte une échéance passée : la proposer telle
      // quelle ferait planter le sélecteur (date initiale avant la première
      // date permise). On part d'aujourd'hui.
      initialDate: current.isBefore(first) ? first : current,
      firstDate: first,
      lastDate: today.add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() => due ? _dueDate = picked : _scheduledFor = picked);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_scheduledFor.isAfter(_dueDate)) {
      setState(() => _error = 'L’échéance ne peut pas précéder le jour prévu.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    String? orNull(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    final PlanningTaskDraft draft = (
      title: _title.text.trim(),
      type: _type,
      assignedToId: _assignedToId!,
      scheduledFor: isoDay(_scheduledFor),
      dueDate: isoDay(_dueDate),
      zone: orNull(_zone),
      description: orNull(_description),
    );
    final actions = ref.read(planningActionsProvider);
    final existing = widget.existing;
    try {
      final task = existing == null
          ? await actions.create(_id, draft)
          : await actions.update(existing, draft);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '« ${task.title} » planifiée jusqu’au ${formatIsoDay(task.dueDate)}.',
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
    final members = ref.watch(assignableMembersProvider).value ?? const [];

    return FormPanelFrame(
      formKey: _formKey,
      title: widget.existing == null ? 'Nouvelle tâche' : 'Modifier la tâche',
      saving: _saving,
      error: _error,
      submitLabel: 'Enregistrer la tâche',
      onSubmit: _saving ? null : _submit,
      children: [
        const AmpereFieldLabel('Intitulé'),
        TextFormField(
          controller: _title,
          enabled: !_saving,
          maxLength: 120,
          decoration: const InputDecoration(
            hintText: 'Compter les câbles de la zone A',
          ),
          validator: (v) => (v ?? '').trim().length < 2
              ? 'Intitulé : 2 caractères minimum'
              : null,
        ),
        const AmpereFieldLabel('Type'),
        DropdownButtonFormField<PlanningTaskType>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: _type,
          isExpanded: true,
          items: [
            for (final t in PlanningTaskType.values)
              DropdownMenuItem(value: t, child: Text(t.label)),
          ],
          onChanged: _saving ? null : (v) => setState(() => _type = v ?? _type),
        ),
        const SizedBox(height: 16),
        const AmpereFieldLabel('Confiée à'),
        DropdownButtonFormField<String>(
          icon: const Icon(LucideIcons.chevronDown, size: 17),
          initialValue: members.any((m) => m.id == _assignedToId)
              ? _assignedToId
              : null,
          isExpanded: true,
          hint: const Text('Choisir un membre'),
          items: [
            for (final m in members)
              DropdownMenuItem(value: m.id, child: Text(m.fullName)),
          ],
          onChanged: _saving ? null : (v) => setState(() => _assignedToId = v),
          validator: (v) => v == null ? 'Choisissez un membre' : null,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _dateButton(
                label: 'Jour prévu',
                value: _scheduledFor,
                onTap: () => _pick(due: false),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _dateButton(
                label: 'Échéance',
                value: _dueDate,
                onTap: () => _pick(due: true),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const AmpereFieldLabel('Zone'),
        TextFormField(
          controller: _zone,
          enabled: !_saving,
          maxLength: 100,
          decoration: const InputDecoration(hintText: 'Zone A, rayon 3…'),
        ),
        const AmpereFieldLabel('Consignes'),
        TextFormField(
          controller: _description,
          enabled: !_saving,
          maxLength: 1000,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Ce qu’il faut vérifier, où, comment…',
          ),
        ),
      ],
    );
  }

  Widget _dateButton({
    required String label,
    required DateTime value,
    required VoidCallback onTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AmpereFieldLabel(label),
        OutlinedButton.icon(
          onPressed: _saving ? null : onTap,
          icon: const Icon(LucideIcons.calendar, size: 16),
          label: Text(formatIsoDay(isoDay(value))),
        ),
      ],
    );
  }
}
