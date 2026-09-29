import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../ui/widgets/screen_state.dart';
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';

/// Contact clients ciblé (P2 n°23, spec §28) : les clients qui ont acheté la
/// catégorie de ce produit (ou une catégorie sœur), du plus fidèle au moins
/// fidèle, chacun avec son message à modèle fixe. On RELIT puis on copie :
/// l'envoi (SMS, WhatsApp, e-mail) reste un geste humain, aucune intégration.
class ProspectsDialog extends ConsumerStatefulWidget {
  const ProspectsDialog({super.key, required this.product});

  final Product product;

  @override
  ConsumerState<ProspectsDialog> createState() => _ProspectsDialogState();
}

class _ProspectsDialogState extends ConsumerState<ProspectsDialog> {
  late final Future<List<Map<String, dynamic>>> _prospects = ref
      .read(catalogApiProvider)
      .prospects(widget.product.id);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Clients à prévenir — ${widget.product.name}'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _prospects,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              final error = snapshot.error;
              return ScreenStateView(
                status: ScreenStatus.error,
                message: error is ApiException
                    ? error.userMessage
                    : 'La liste n’a pas pu être chargée.',
              );
            }
            final items = snapshot.data;
            if (items == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (items.isEmpty) {
              return const ScreenStateView(
                status: ScreenStatus.empty,
                title: 'Aucun client',
                message:
                    'Aucun client n’a encore acheté dans cette catégorie ni '
                    'dans une catégorie voisine.',
              );
            }
            return ListView(
              children: [
                for (final p in items)
                  ExpansionTile(
                    title: Text(p['name'] as String),
                    subtitle: Text(
                      [
                        if (p['phone'] != null) p['phone'] as String,
                        if (p['email'] != null) p['email'] as String,
                        '${p['purchases']} achat(s) · dernier le '
                            '${formatDate(DateTime.parse(p['lastPurchaseAt'] as String).toLocal())}',
                      ].join(' · '),
                    ),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    children: [
                      SelectableText(p['message'] as String),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () => _copy(p),
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copier le message'),
                        ),
                      ),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }

  Future<void> _copy(Map<String, dynamic> prospect) async {
    await Clipboard.setData(ClipboardData(text: prospect['message'] as String));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Message pour ${prospect['name']} copié.')),
    );
  }
}
