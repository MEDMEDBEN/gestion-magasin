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

  test('la build release peut joindre l’API', () {
    expect(manifest, contains('android.permission.INTERNET'));
  });
}
