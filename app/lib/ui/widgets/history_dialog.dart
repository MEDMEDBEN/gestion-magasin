import 'package:flutter/material.dart';

import '../../core/error/api_exception.dart';
import 'screen_state.dart';

/// Une ligne d'historique : « VNT-2026-00012 · 27/09/2026 », montant à droite.
typedef HistoryEntry = ({String title, String subtitle, String trailing});

/// Historique en lecture seule (achats d'un client, commandes passées à un
/// fournisseur) : la liste que le serveur rend, filtrée par le serveur.
Future<void> showHistory(
  BuildContext context, {
  required String title,
  required String empty,
  required Future<List<HistoryEntry>> Function() load,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        height: 420,
        child: FutureBuilder<List<HistoryEntry>>(
          future: load(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              final error = snapshot.error;
              return ScreenStateView(
                status: error is ApiException && error.isOffline
                    ? ScreenStatus.offline
                    : ScreenStatus.error,
                message: error is ApiException
                    ? error.userMessage
                    : 'Historique indisponible',
              );
            }
            final items = snapshot.data;
            if (items == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (items.isEmpty) {
              return ScreenStateView(
                status: ScreenStatus.empty,
                title: 'Rien à afficher',
                message: empty,
              );
            }
            return ListView(
              children: [
                for (final item in items)
                  ListTile(
                    title: Text(item.title),
                    subtitle: Text(item.subtitle),
                    trailing: Text(item.trailing),
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
    ),
  );
}
