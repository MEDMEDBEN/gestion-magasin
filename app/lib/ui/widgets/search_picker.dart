import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Choix dans une LONGUE liste (produits, fournisseurs) : le champ ouvre une
/// fenêtre avec une barre de recherche, la liste se filtre à la frappe. Une
/// liste déroulante de 1 000 produits obligeait à tout faire défiler.
///
/// Champ CONTRÔLÉ : `value` vient du parent (un remplissage automatique, la
/// lecture d'une facture par exemple, s'affiche aussitôt) ; le choix remonte
/// par `onChanged`.
class SearchPickerField<T> extends StatelessWidget {
  const SearchPickerField({
    super.key,
    required this.options,
    required this.idOf,
    required this.labelOf,
    required this.value,
    required this.hint,
    this.searchTextOf,
    this.onChanged,
    this.validator,
    this.noneLabel,
    this.decoration,
    this.title,
  });

  final List<T> options;
  final String Function(T option) idOf;
  final String Function(T option) labelOf;

  /// Texte cherché (nom, référence, code-barres…) ; à défaut, le libellé.
  final String Function(T option)? searchTextOf;
  final String? value;
  final String hint;

  /// `null` = champ en lecture seule.
  final ValueChanged<String?>? onChanged;
  final FormFieldValidator<String>? validator;

  /// Libellé d'un choix « aucun » (ex. « Non précisé ») ; absent = obligatoire.
  final String? noneLabel;
  final InputDecoration? decoration;

  /// Titre de la fenêtre de recherche ; à défaut, `hint`.
  final String? title;

  @override
  Widget build(BuildContext context) {
    final selected = options.where((o) => idOf(o) == value).firstOrNull;
    return FormField<String>(
      // Une valeur posée par le parent recrée le champ : il l'affiche et la
      // valide telle quelle.
      key: ValueKey(value),
      initialValue: value,
      validator: validator,
      builder: (field) {
        final enabled = onChanged != null;
        return InkWell(
          onTap: enabled ? () => _open(context, field) : null,
          child: InputDecorator(
            isEmpty: selected == null && noneLabel == null,
            decoration: (decoration ?? const InputDecoration()).copyWith(
              hintText: hint,
              errorText: field.errorText,
              enabled: enabled,
              suffixIcon: const Icon(LucideIcons.search, size: 17),
            ),
            child: Text(
              selected != null ? labelOf(selected) : (noneLabel ?? ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }

  Future<void> _open(BuildContext context, FormFieldState<String> field) async {
    final picked = await showDialog<_Picked>(
      context: context,
      builder: (_) => _SearchDialog<T>(
        title: title ?? hint,
        options: options,
        idOf: idOf,
        labelOf: labelOf,
        searchTextOf: searchTextOf ?? labelOf,
        noneLabel: noneLabel,
        selectedId: value,
      ),
    );
    if (picked == null) return;
    field.didChange(picked.id);
    onChanged?.call(picked.id);
  }
}

/// Choix rendu par la fenêtre ; `id == null` = « aucun » choisi (≠ annulé).
class _Picked {
  const _Picked(this.id);
  final String? id;
}

class _SearchDialog<T> extends StatefulWidget {
  const _SearchDialog({
    required this.title,
    required this.options,
    required this.idOf,
    required this.labelOf,
    required this.searchTextOf,
    required this.noneLabel,
    required this.selectedId,
  });

  final String title;
  final List<T> options;
  final String Function(T) idOf;
  final String Function(T) labelOf;
  final String Function(T) searchTextOf;
  final String? noneLabel;
  final String? selectedId;

  @override
  State<_SearchDialog<T>> createState() => _SearchDialogState<T>();
}

class _SearchDialogState<T> extends State<_SearchDialog<T>> {
  String _query = '';

  /// Au-delà, la liste demande de préciser la recherche : afficher 5 000
  /// lignes n'aide personne à trouver la sienne.
  static const _maxShown = 100;

  @override
  Widget build(BuildContext context) {
    final terms = _query.toLowerCase().split(' ').where((t) => t.isNotEmpty);
    final matches = widget.options
        .where((o) {
          final text = widget.searchTextOf(o).toLowerCase();
          return terms.every(text.contains);
        })
        .toList(growable: false);
    final shown = matches.take(_maxShown).toList(growable: false);
    final size = MediaQuery.sizeOf(context);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 560,
        height: size.height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                widget.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                autocorrect: false,
                decoration: const InputDecoration(
                  prefixIcon: Icon(LucideIcons.search, size: 17),
                  hintText: 'Rechercher…',
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            // Au-dessus de la liste : visible sans rien faire défiler.
            if (matches.length > _maxShown)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  '${matches.length} résultats, $_maxShown affichés : '
                  'précisez la recherche.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  if (widget.noneLabel != null && _query.isEmpty)
                    ListTile(
                      title: Text(widget.noneLabel!),
                      selected: widget.selectedId == null,
                      onTap: () =>
                          Navigator.of(context).pop(const _Picked(null)),
                    ),
                  for (final o in shown)
                    ListTile(
                      title: Text(widget.labelOf(o)),
                      selected: widget.idOf(o) == widget.selectedId,
                      onTap: () =>
                          Navigator.of(context).pop(_Picked(widget.idOf(o))),
                    ),
                  if (matches.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Aucun résultat',
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Annuler'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
