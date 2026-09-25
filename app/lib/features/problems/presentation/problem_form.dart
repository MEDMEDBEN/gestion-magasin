import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../catalog/application/catalog_controller.dart';
import '../application/problems_controller.dart';
import '../data/problem_models.dart';
import '../data/problems_api.dart';

Future<void> openProblemForm(BuildContext context) =>
    openFormPanel<void>(context, const ProblemForm());

/// Signaler : un titre, une catégorie, ce qui a été constaté.
///
/// Le produit concerné est FACULTATIF et choisi dans le catalogue local — un
/// signalement reste utile même quand on ne sait pas quel article est en cause
/// (poste en panne, étagère abîmée).
class ProblemForm extends ConsumerStatefulWidget {
  const ProblemForm({super.key});

  @override
  ConsumerState<ProblemForm> createState() => _ProblemFormState();
}

class _ProblemFormState extends ConsumerState<ProblemForm> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  ProblemCategory _category = ProblemCategory.wrongStock;
  ProblemPriority _priority = ProblemPriority.normal;
  String? _productId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(activeProductsProvider).value ?? const [];

    return FormPanelFrame(
      formKey: _formKey,
      title: 'Signaler un problème',
      submitLabel: 'Envoyer',
      saving: _saving,
      error: _error,
      onSubmit: _saving ? null : _submit,
      children: [
        TextFormField(
          controller: _title,
          decoration: const InputDecoration(labelText: 'Titre'),
          maxLength: 120,
          validator: (value) =>
              (value ?? '').trim().length < 3 ? 'Titre trop court' : null,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<ProblemCategory>(
          initialValue: _category,
          decoration: const InputDecoration(labelText: 'Catégorie'),
          items: [
            for (final category in ProblemCategory.values)
              if (category != ProblemCategory.unknown)
                DropdownMenuItem(value: category, child: Text(category.label)),
          ],
          onChanged: (value) =>
              setState(() => _category = value ?? ProblemCategory.other),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<ProblemPriority>(
          initialValue: _priority,
          decoration: const InputDecoration(labelText: 'Priorité'),
          items: [
            for (final priority in ProblemPriority.values)
              DropdownMenuItem(value: priority, child: Text(priority.label)),
          ],
          onChanged: (value) =>
              setState(() => _priority = value ?? ProblemPriority.normal),
        ),
        const SizedBox(height: 12),
        // Facultatif : beaucoup de problèmes ne visent aucun article précis.
        DropdownButtonFormField<String?>(
          initialValue: _productId,
          decoration: const InputDecoration(
            labelText: 'Produit concerné (facultatif)',
          ),
          items: [
            const DropdownMenuItem<String?>(child: Text('Aucun')),
            for (final product in products.take(200))
              DropdownMenuItem(value: product.id, child: Text(product.name)),
          ],
          onChanged: (value) => setState(() => _productId = value),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _description,
          decoration: const InputDecoration(
            labelText: 'Ce que vous avez constaté',
          ),
          minLines: 3,
          maxLines: 6,
          maxLength: 2000,
          validator: (value) => (value ?? '').trim().length < 5
              ? 'Décrivez ce qui a été constaté'
              : null,
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(problemsApiProvider)
          .create(
            title: _title.text.trim(),
            category: _category,
            description: _description.text.trim(),
            priority: _priority,
            productId: _productId,
          );
      // TOUTE la famille est relue : la liste qu'on quitte peut être filtrée
      // autrement (« tous », « les miens »), et elle doit montrer le
      // signalement qu'on vient de déposer.
      ref.invalidate(problemsProvider);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (error) {
      setState(() {
        _saving = false;
        _error = error.userMessage;
      });
    }
  }
}
