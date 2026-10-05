import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/dates.dart';
import 'package:gestion_magasin/ui/widgets/history_dialog.dart';
import 'package:gestion_magasin/ui/widgets/period_filter.dart';

/// Filtre par dates des historiques (demande MEDMEDBEN du 2026-10-05).
void main() {
  test('une date est dans la période, bornes INCLUSES', () {
    const period = (from: '2026-10-01', to: '2026-10-05');
    expect(inPeriod(period, DateTime(2026, 10, 1, 0, 0)), isTrue);
    expect(inPeriod(period, DateTime(2026, 10, 5, 23, 59)), isTrue);
    expect(inPeriod(period, DateTime(2026, 9, 30, 23, 59)), isFalse);
    expect(inPeriod(period, DateTime(2026, 10, 6)), isFalse);
    expect(inPeriod(allTime, DateTime(2001)), isTrue);
  });

  test('libellés : un jour, une plage, tout', () {
    final today = DateUtils.dateOnly(DateTime.now());
    expect(describePeriod(singleDay(today)), 'Aujourd’hui');
    expect(
      describePeriod((from: '2026-10-01', to: '2026-10-05')),
      'Du 01/10/2026 au 05/10/2026',
    );
    expect(
      describePeriod((from: '2026-09-12', to: '2026-09-12')),
      isoDay(today) == '2026-09-12' ? 'Aujourd’hui' : '12/09/2026',
    );
    expect(describePeriod(allTime), 'Tout');
  });

  testWidgets('historique : « Hier » ne garde que les lignes d’hier', (
    tester,
  ) async {
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showHistory(
              context,
              title: 'Achats',
              empty: 'Rien',
              load: () async => [
                (title: 'VNT-1', subtitle: '', trailing: '', at: now),
                (title: 'VNT-2', subtitle: '', trailing: '', at: yesterday),
              ],
            ),
            child: const Text('ouvrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    expect(find.text('VNT-1'), findsOneWidget);
    expect(find.text('VNT-2'), findsOneWidget);

    await tester.tap(find.byType(PeriodFilter));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hier'));
    await tester.pumpAndSettle();

    expect(find.text('VNT-1'), findsNothing);
    expect(find.text('VNT-2'), findsOneWidget);
  });
}
