import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:printing/printing.dart';

import '../../../core/pdf_printing.dart';
import '../../../core/providers.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';

/// Imprimantes de CE poste (décision MEDMEDBEN du 2026-10-12) : une par sorte
/// de papier. Choisie, l'impression part DIRECTEMENT, au bon format, sans
/// boîte de dialogue ; sans choix, la boîte s'ouvre avec le format exact.
/// Réglage local au poste (chaque caisse a ses imprimantes).
class PrintersCard extends ConsumerStatefulWidget {
  const PrintersCard({super.key});

  @override
  ConsumerState<PrintersCard> createState() => _PrintersCardState();
}

class _PrintersCardState extends ConsumerState<PrintersCard> {
  final _chosen = <PaperKind, String?>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(localSettingsStoreProvider);
    for (final kind in PaperKind.values) {
      final url = await savedPrinter(store, kind);
      if (mounted) setState(() => _chosen[kind] = url);
    }
  }

  Future<void> _choose(PaperKind kind) async {
    final printer = await Printing.pickPrinter(
      context: context,
      title: 'Imprimante — ${kind.title}',
    );
    if (printer == null || !mounted) return;
    await savePrinter(ref.read(localSettingsStoreProvider), kind, printer.url);
    if (mounted) setState(() => _chosen[kind] = printer.url);
  }

  Future<void> _forget(PaperKind kind) async {
    await savePrinter(ref.read(localSettingsStoreProvider), kind, null);
    if (mounted) setState(() => _chosen[kind] = null);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Choisissez une imprimante par sorte de papier : l’impression '
              'partira directement, au bon format.',
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
            for (final kind in PaperKind.values)
              Row(
                children: [
                  Icon(
                    switch (kind) {
                      PaperKind.ticket => LucideIcons.receipt,
                      PaperKind.etiquette => LucideIcons.tag,
                      PaperKind.document => LucideIcons.fileText,
                    },
                    size: 18,
                    color: colors.ink2,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          kind.title,
                          style: AmpereType.rowTitle.copyWith(
                            color: colors.ink,
                          ),
                        ),
                        Text(
                          _chosen[kind] ?? 'Boîte d’impression à chaque fois',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AmpereType.meta.copyWith(
                            color: _chosen[kind] == null
                                ? colors.ink3
                                : colors.ok,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_chosen[kind] != null)
                    IconButton(
                      tooltip: 'Oublier cette imprimante',
                      icon: const Icon(LucideIcons.x, size: 16),
                      onPressed: () => _forget(kind),
                    ),
                  TextButton(
                    onPressed: () => _choose(kind),
                    child: Text(_chosen[kind] == null ? 'Choisir' : 'Changer'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
