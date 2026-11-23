import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/local/local_settings_store.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';

/// Ce que porte l'étiquette (demande MEDMEDBEN du 2026-11-23) : au choix —
/// code-barres seul, nom seul, nom + prix… Valeurs = celles du serveur.
enum LabelPart {
  name('NAME', 'Nom', LucideIcons.type),
  price('PRICE', 'Prix', LucideIcons.tag),
  barcode('BARCODE', 'Code-barres', LucideIcons.barcode);

  const LabelPart(this.code, this.title, this.icon);
  final String code;
  final String title;
  final IconData icon;
}

typedef LabelRequest = ({int copies, Set<LabelPart> parts});

const _partsKey = 'labels.parts';

/// Contenu choisi à la dernière impression sur CE poste (tout par défaut).
Future<Set<LabelPart>> savedLabelParts(LocalSettingsStore store) async {
  final saved = (await store.read(_partsKey))?.split(',') ?? const [];
  final parts = {
    for (final p in LabelPart.values)
      if (saved.contains(p.code)) p,
  };
  return parts.isEmpty ? LabelPart.values.toSet() : parts;
}

Future<void> saveLabelParts(LocalSettingsStore store, Set<LabelPart> parts) =>
    store.write(_partsKey, parts.map((p) => p.code).join(','));

/// Impression des étiquettes (spec §8ter) : le CONTENU et le nombre
/// d'exemplaires par produit — le support est FIXE, 35 × 45 mm portrait
/// (décision MEDMEDBEN du 2026-11-13). Rend `null` si l'utilisateur annule.
Future<LabelRequest?> askLabels(
  BuildContext context, {
  required int productCount,
  required Set<LabelPart> parts,
  String? productName,
}) {
  return showDialog<LabelRequest>(
    context: context,
    builder: (context) => _LabelsDialog(
      productCount: productCount,
      parts: parts,
      productName: productName,
    ),
  );
}

class _LabelsDialog extends StatefulWidget {
  const _LabelsDialog({
    required this.productCount,
    required this.parts,
    this.productName,
  });

  final int productCount;
  final Set<LabelPart> parts;
  final String? productName;

  @override
  State<_LabelsDialog> createState() => _LabelsDialogState();
}

class _LabelsDialogState extends State<_LabelsDialog> {
  final _copies = TextEditingController(text: '1');
  late final Set<LabelPart> _parts = {...widget.parts};
  String? _error;

  @override
  void dispose() {
    _copies.dispose();
    super.dispose();
  }

  void _toggle(LabelPart part) => setState(() {
    if (!_parts.remove(part)) _parts.add(part);
  });

  void _confirm() {
    if (_parts.isEmpty) return;
    final copies = int.tryParse(_copies.text.trim());
    // Mêmes bornes que le serveur : 1 à 100 par produit, 1 000 au total.
    if (copies == null || copies < 1 || copies > 100) {
      setState(() => _error = 'Entre 1 et 100 par produit');
      return;
    }
    if (copies * widget.productCount > 1000) {
      setState(() => _error = '1 000 étiquettes au plus par impression');
      return;
    }
    Navigator.of(context).pop((copies: copies, parts: {..._parts}));
  }

  @override
  Widget build(BuildContext context) {
    final c = AmpereColors.of(context);
    final title = widget.productCount == 1 && widget.productName != null
        ? 'Étiquette — ${widget.productName}'
        : 'Étiquettes — ${widget.productCount} produit(s)';
    return AlertDialog(
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 420,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _LabelPreview(parts: _parts, name: widget.productName),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Contenu',
                    style: AmpereType.label.copyWith(color: c.ink2),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final part in LabelPart.values)
                        FilterChip(
                          key: ValueKey('label-part-${part.code}'),
                          avatar: Icon(part.icon, size: 16),
                          label: Text(part.title),
                          selected: _parts.contains(part),
                          showCheckmark: false,
                          onSelected: (_) => _toggle(part),
                        ),
                    ],
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 150),
                    child: _parts.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Choisissez au moins un élément.',
                              style: AmpereType.meta.copyWith(color: c.error),
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _copies,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Exemplaires par produit',
                      errorText: _error,
                    ),
                    onSubmitted: (_) => _confirm(),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '35 × 45 mm, portrait'
                    '${_parts.contains(LabelPart.price) ? ' · prix du tarif par défaut' : ''}',
                    style: AmpereType.meta.copyWith(color: c.ink3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton.icon(
          onPressed: _parts.isEmpty ? null : _confirm,
          icon: const Icon(LucideIcons.printer, size: 18),
          label: const Text('Imprimer'),
        ),
      ],
    );
  }
}

/// Aperçu de l'étiquette (proportions 35 × 45) : ce qui sera imprimé, mis en
/// page comme le PDF du serveur.
class _LabelPreview extends StatelessWidget {
  const _LabelPreview({required this.parts, this.name});

  final Set<LabelPart> parts;
  final String? name;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF111111);
    final hasName = parts.contains(LabelPart.name);
    final hasPrice = parts.contains(LabelPart.price);
    final hasBarcode = parts.contains(LabelPart.barcode);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 105,
      height: 135,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AmpereColors.of(context).line),
        boxShadow: const [
          BoxShadow(blurRadius: 8, offset: Offset(0, 2), color: Colors.black26),
        ],
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: Column(
          key: ValueKey(parts.map((p) => p.code).join()),
          mainAxisAlignment: hasBarcode
              ? MainAxisAlignment.start
              : MainAxisAlignment.center,
          children: [
            if (hasName)
              Text(
                name ?? 'Nom du produit',
                textAlign: TextAlign.center,
                maxLines: hasBarcode ? 2 : 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ink,
                  fontWeight: FontWeight.w700,
                  fontSize: hasBarcode ? 8 : 10.5,
                  height: 1.15,
                ),
              ),
            if (hasName && hasPrice) const SizedBox(height: 3),
            if (hasPrice)
              FittedBox(
                child: Text(
                  '1 250,00 DA',
                  style: TextStyle(
                    color: ink,
                    fontWeight: FontWeight.w800,
                    fontSize: hasBarcode ? 14 : 18,
                  ),
                ),
              ),
            if (hasBarcode) ...[
              if (hasName || hasPrice) const SizedBox(height: 4),
              const Expanded(child: _Bars()),
              const SizedBox(height: 2),
              const Text(
                '2000000000015',
                style: TextStyle(color: ink, fontSize: 7, letterSpacing: 0.6),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Barres décoratives (l'aperçu ne doit pas être scanné).
class _Bars extends StatelessWidget {
  const _Bars();

  static const _widths = [2, 1, 1, 3, 1, 2, 1, 1, 2, 3, 1, 1, 2, 1, 3, 1, 2];

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, w) in _widths.indexed)
          Expanded(
            flex: w,
            child: ColoredBox(
              color: i.isEven ? const Color(0xFF111111) : Colors.white,
            ),
          ),
      ],
    );
  }
}
