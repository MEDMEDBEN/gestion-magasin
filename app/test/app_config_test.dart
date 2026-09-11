import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/config/app_config.dart';

/// Audit M7 : une build RELEASE ne parle jamais au serveur en clair.
void main() {
  test('release pointée sur http:// : refus de démarrer', () {
    expect(
      () => AppConfig.assertSecureTransport(isRelease: true, url: 'http://api.magasin.dz/api'),
      throwsStateError,
    );
  });

  test('release en https:// : accepté', () {
    AppConfig.assertSecureTransport(isRelease: true, url: 'https://api.magasin.dz/api');
  });

  test('debug sur http://localhost : permis pour le développement', () {
    AppConfig.assertSecureTransport(isRelease: false, url: 'http://localhost:3000/api');
  });
}
