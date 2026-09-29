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
  static const _offlineUserKey = 'offline_user';
  static const _serverContactKey = 'server_contact_at';
  static const _offlineSeenKey = 'offline_seen_at';

  Future<String?> readAccessToken() => _storage.read(key: _accessTokenKey);
  Future<String?> readRefreshToken() => _storage.read(key: _refreshTokenKey);

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
  }

  /// Fiche du compte connecté (JSON), gardée pour ouvrir l'app HORS LIGNE : au
  /// démarrage sans réseau, on ne peut pas demander au serveur qui est
  /// connecté. Chiffrée comme les tokens, effacée avec eux. Écrite SEULEMENT
  /// après une réponse du serveur sur le compte (connexion, `/auth/me`) : sa
  /// date est celle du dernier contact où il l'a reconnu — un simple
  /// renouvellement de token ne la rajeunit pas (audit sécurité, point 1).
  Future<void> saveOfflineUser(String userJson) async {
    await _storage.write(key: _offlineUserKey, value: userJson);
    await _storage.write(
      key: _serverContactKey,
      value: DateTime.now().toUtc().toIso8601String(),
    );
    await _storage.delete(key: _offlineSeenKey);
  }

  /// Fiche gardée, dernier contact reconnu par le serveur, et instant le plus
  /// tardif vu par l'appareil hors ligne depuis (contre l'horloge reculée).
  Future<({String userJson, DateTime serverContactAt, DateTime? lastSeen})?>
  readOfflineUser() async {
    final json = await _storage.read(key: _offlineUserKey);
    final at = DateTime.tryParse(
      await _storage.read(key: _serverContactKey) ?? '',
    );
    if (json == null || at == null) return null;
    final seen = DateTime.tryParse(
      await _storage.read(key: _offlineSeenKey) ?? '',
    );
    return (userJson: json, serverContactAt: at, lastSeen: seen);
  }

  /// Retient l'instant présent s'il est le plus tardif vu hors ligne.
  Future<void> markOfflineSeen() async {
    final now = DateTime.now().toUtc();
    final seen = DateTime.tryParse(
      await _storage.read(key: _offlineSeenKey) ?? '',
    );
    if (seen == null || now.isAfter(seen)) {
      await _storage.write(key: _offlineSeenKey, value: now.toIso8601String());
    }
  }

  Future<void> clearOfflineUser() async {
    await _storage.delete(key: _offlineUserKey);
    await _storage.delete(key: _serverContactKey);
    await _storage.delete(key: _offlineSeenKey);
  }

  Future<void> clear() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
    await clearOfflineUser();
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
