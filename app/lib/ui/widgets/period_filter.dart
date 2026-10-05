import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/dates.dart';

/// Période d'un historique : jours `AAAA-MM-JJ` INCLUS ; `null` = sans borne.
/// Même contrat que le serveur (`DayPeriodQueryDto` : jours civils d'Alger).
typedef HistoryPeriod = ({String? from, String? to});

/// Sans filtre : tout l'historique.
const HistoryPeriod allTime = (from: null, to: null);

DateTime _today() => DateUtils.dateOnly(DateTime.now());

/// Les `n` derniers jours, aujourd'hui compris.
HistoryPeriod lastDays(int n) => (
  from: isoDay(_today().subtract(Duration(days: n - 1))),
  to: isoDay(_today()),
);

/// Un seul jour (« qu'ai-je vendu ce jour-là ? »).
HistoryPeriod singleDay(DateTime day) => (from: isoDay(day), to: isoDay(day));

/// Libellé court d'une période : « Aujourd'hui », « 05/10/2026 », « du … au … ».
String describePeriod(HistoryPeriod period) {
  final (:from, :to) = period;
  if (from == null && to == null) return 'Tout';
  final today = isoDay(_today());
  if (from == to) return from == today ? 'Aujourd’hui' : formatIsoDay(from!);
  if (from == null) return 'Jusqu’au ${formatIsoDay(to!)}';
  if (to == null) return 'Depuis le ${formatIsoDay(from)}';
  return 'Du ${formatIsoDay(from)} au ${formatIsoDay(to)}';
}

/// Sélecteur de période d'un historique (demande MEDMEDBEN du 2026-10-05) :
/// raccourcis usuels, ou DATES PRÉCISES au calendrier — un jour donné, ou du
/// … au … . Remplace les seuls « 7 / 30 / 365 jours ».
class PeriodFilter extends StatelessWidget {
  const PeriodFilter({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowAll = true,
  });

  final HistoryPeriod value;
  final ValueChanged<HistoryPeriod> onChanged;

  /// « Tout » proposé (un journal très volumineux peut l'interdire).
  final bool allowAll;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () => _choose(context),
      icon: const Icon(LucideIcons.calendarRange, size: 17),
      label: Text(describePeriod(value)),
    );
  }

  Future<void> _choose(BuildContext context) async {
    final today = _today();
    final presets = <(String, HistoryPeriod)>[
      ('Aujourd’hui', singleDay(today)),
      ('Hier', singleDay(today.subtract(const Duration(days: 1)))),
      ('7 derniers jours', lastDays(7)),
      ('30 derniers jours', lastDays(30)),
      (
        'Ce mois-ci',
        (from: isoDay(DateTime(today.year, today.month)), to: isoDay(today)),
      ),
      ('12 derniers mois', lastDays(365)),
      if (allowAll) ('Tout', allTime),
    ];
    final picked = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (label, period) in presets)
                ListTile(
                  title: Text(label),
                  selected: period == value,
                  onTap: () => Navigator.of(context).pop(period),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(LucideIcons.calendarDays),
                title: const Text('Dates précises…'),
                subtitle: const Text('Un jour, ou du … au …'),
                onTap: () => Navigator.of(context).pop('custom'),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    if (picked is HistoryPeriod) {
      onChanged(picked);
      return;
    }
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: today,
      initialDateRange: _rangeOf(value, today),
      helpText: 'Choisir la période (un jour : touchez-le deux fois)',
      saveText: 'Appliquer',
    );
    if (range == null) return;
    onChanged((from: isoDay(range.start), to: isoDay(range.end)));
  }

  static DateTimeRange? _rangeOf(HistoryPeriod period, DateTime today) {
    final from = DateTime.tryParse(period.from ?? '');
    final to = DateTime.tryParse(period.to ?? '');
    if (from == null) return null;
    return DateTimeRange(start: from, end: to ?? today);
  }
}
