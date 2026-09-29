import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/photos.dart';
import '../../../core/quantity.dart';
import '../data/receptions_api.dart';

/// Une ligne lue sur la facture : produit reconnu (ou non), quantité et prix
/// unitaire HT proposés. Une PROPOSITION : le formulaire la montre, on corrige.
typedef ScannedLine = ({
  String text,
  String? productId,
  String? productName,
  Quantity? quantity,
  int? unitPriceHt,
});

/// Lecture d'une facture fournisseur (P2 n°24, spec §28) : photo → serveur →
/// lignes proposées. Rend `null` si abandonné ou en échec (message affiché).
/// Les lignes sans produit reconnu sont montrées pour être saisies à la main.
/// Une lecture à la fois : un double appui ne lance pas deux scans.
bool _scanning = false;

Future<List<ScannedLine>?> scanInvoice(
  BuildContext context,
  WidgetRef ref,
) async {
  if (_scanning) return null;
  _scanning = true;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final Uint8List? photo;
    try {
      photo = await ref.read(pickDocumentPhotoProvider)();
    } on Exception {
      // Appareil photo refusé ou indisponible.
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Photo illisible ou impossible sur cet appareil.'),
        ),
      );
      return null;
    }
    if (photo == null) return null;
    messenger.showSnackBar(
      const SnackBar(content: Text('Lecture de la facture…')),
    );
    return await _read(ref, messenger, photo);
  } finally {
    _scanning = false;
  }
}

Future<List<ScannedLine>?> _read(
  WidgetRef ref,
  ScaffoldMessengerState messenger,
  Uint8List photo,
) async {
  try {
    final raw = await ref.read(receptionsApiProvider).scanInvoice(photo);
    messenger.hideCurrentSnackBar();
    return [
      for (final l in raw)
        (
          text: l['text'] as String,
          productId: l['productId'] as String?,
          productName: l['productName'] as String?,
          quantity: switch (l['quantity']) {
            final String q => quantityFromJson(q),
            _ => null,
          },
          unitPriceHt: l['unitPriceHt'] as int?,
        ),
    ];
  } on ApiException catch (error) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error.userMessage)));
    return null;
  }
}

/// Bilan de la lecture : ce qui a été repris, ce qu'il reste à saisir. Toujours
/// affiché — l'utilisateur sait qu'il doit VÉRIFIER avant d'enregistrer.
Future<void> showScanSummary(
  BuildContext context, {
  required List<ScannedLine> applied,
  required List<ScannedLine> ignored,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Facture lue — à vérifier'),
      content: SizedBox(
        width: 520,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              applied.isEmpty
                  ? 'Aucune ligne n’a pu être reprise.'
                  : '${applied.length} ligne(s) reprise(s) dans le formulaire :',
            ),
            for (final l in applied)
              ListTile(
                dense: true,
                title: Text(l.productName ?? l.text),
                // Le texte LU : l'utilisateur voit d'où vient le produit.
                isThreeLine: true,
                subtitle: Text(
                  [
                    if (l.quantity case final q?)
                      'quantité ${formatQuantity(q)}',
                    if (l.unitPriceHt case final p?) '${formatDA(p)} HT',
                    l.text,
                  ].join(' · '),
                ),
              ),
            if (ignored.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '${ignored.length} ligne(s) non reconnue(s), à saisir si besoin :',
              ),
              for (final l in ignored)
                ListTile(dense: true, title: Text(l.text)),
            ],
            const SizedBox(height: 8),
            const Text(
              'La lecture peut se tromper : vérifiez chaque quantité et chaque '
              'prix avant d’enregistrer.',
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Vérifier'),
        ),
      ],
    ),
  );
}
