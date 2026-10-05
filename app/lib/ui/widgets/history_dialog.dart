import 'package:flutter/material.dart';

import '../../core/error/api_exception.dart';
import 'period_filter.dart';
import 'screen_state.dart';

/// Une ligne d'historique : « VNT-2026-00012 · 27/09/2026 », montant à droite.
/// `at` : date de l'opération — dès qu'une ligne en porte une, la fenêtre
/// propose le filtre par dates (demande MEDMEDBEN du 2026-10-05).
typedef HistoryEntry = ({
  String title,
  String subtitle,
  String trailing,
  DateTime? at,
});

/// Historique en lecture seule (achats d'un client, commandes passées à un
/// fournisseur) : la liste que le serveur rend, filtrée par le serveur ; la
/// période se choisit ensuite sur l'appareil.
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
        child: _HistoryBody(load: load, empty: empty),
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

class _HistoryBody extends StatefulWidget {
  const _HistoryBody({required this.load, required this.empty});

  final Future<List<HistoryEntry>> Function() load;
  final String empty;

  @override
  State<_HistoryBody> createState() => _HistoryBodyState();
}

class _HistoryBodyState extends State<_HistoryBody> {
  late final Future<List<HistoryEntry>> _items = widget.load();
  HistoryPeriod _period = allTime;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<HistoryEntry>>(
      future: _items,
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
            message: widget.empty,
          );
        }
        final dated = items.any((i) => i.at != null);
        final shown = [
          for (final i in items)
            if (!dated || i.at == null || inPeriod(_period, i.at!)) i,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (dated)
              Align(
                alignment: Alignment.centerLeft,
                child: PeriodFilter(
                  value: _period,
                  onChanged: (p) => setState(() => _period = p),
                ),
              ),
            Expanded(
              child: shown.isEmpty
                  ? const ScreenStateView(
                      status: ScreenStatus.empty,
                      title: 'Rien sur cette période',
                    )
                  : ListView(
                      children: [
                        for (final item in shown)
                          ListTile(
                            title: Text(item.title),
                            subtitle: Text(item.subtitle),
                            trailing: Text(item.trailing),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}
