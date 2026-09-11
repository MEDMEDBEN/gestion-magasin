import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/dates.dart';

/// Formats AMPÈRE §3.3 : `JJ/MM/AAAA` et `JJ/MM/AAAA HH:MM`, en heure LOCALE.
void main() {
  test('date au format JJ/MM/AAAA', () {
    expect(formatDate(DateTime(2026, 9, 5)), '05/09/2026');
  });

  test('horodatage au format JJ/MM/AAAA HH:MM', () {
    expect(formatDateTime(DateTime(2026, 9, 5, 8, 4)), '05/09/2026 08:04');
  });

  test('une date UTC est affichée dans le fuseau local', () {
    final utc = DateTime.utc(2026, 1, 1, 12);
    expect(formatDateTime(utc), formatDateTime(utc.toLocal()));
  });
}
