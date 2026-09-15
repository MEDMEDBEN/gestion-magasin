import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Les tokens vivent UNIQUEMENT ici (chiffré par l'OS) — jamais dans Drift,
/// jamais dans des préférences en clair (CLAUDE.md règle 14, § Sécurité).
class TokenStore {
  TokenStore([FlutterSecureStorage? storage])
    // Depuis flutter_secure_storage 11, le chiffrement fort (AES-GCM +
    // enveloppe RSA-OAEP sur Android, Keychain sur iOS, DPAPI sur Windows)
    // est le comportement PAR DÉFAUT : aucune option à forcer.
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _deviceIdKey = 'device_id';

  Future<String?> readAccessToken() => _storage.read(key: _accessTokenKey);
  Future<String?> readRefreshToken() => _storage.read(key: _refreshTokenKey);

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
  }

  Future<void> clear() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
  }

  /// Identifiant stable de l'appareil : permet à l'admin de révoquer UNE session
  /// (téléphone volé) et trace l'origine des mutations hors-ligne.
  /// Volontairement conservé après un logout — c'est l'appareil, pas la session.
  Future<String> deviceId(String Function() generate) async {
    final existing = await _storage.read(key: _deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final created = generate();
    await _storage.write(key: _deviceIdKey, value: created);
    return created;
  }
}
