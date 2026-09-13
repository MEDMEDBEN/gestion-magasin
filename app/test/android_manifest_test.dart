import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Audit M9 + bloquant de release : verrouille le manifeste Android principal
/// (celui de la build RELEASE — debug/profile ont les leurs).
void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  test('la sauvegarde cloud automatique est désactivée (base locale et secrets)', () {
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:fullBackupContent="false"'));
  });

  test('Android 12+ : ni sauvegarde cloud ni transfert d’appareil (N9)', () {
    expect(manifest, contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
    final rules =
        File('android/app/src/main/res/xml/data_extraction_rules.xml').readAsStringSync();
    for (final section in ['cloud-backup', 'device-transfer']) {
      final start = rules.indexOf('<$section>');
      final end = rules.indexOf('</$section>');
      final body = start < 0 || end < start ? null : rules.substring(start, end);
      expect(body, isNotNull, reason: 'section <$section> absente');
      for (final domain in ['root', 'file', 'database', 'sharedpref', 'external']) {
        expect(body, contains('domain="$domain" path="."'), reason: '$section / $domain');
      }
    }
  });

  test('la build release peut joindre l’API', () {
    expect(manifest, contains('android.permission.INTERNET'));
  });
}
