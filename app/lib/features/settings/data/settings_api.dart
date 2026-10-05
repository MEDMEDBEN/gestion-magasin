import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import '../../catalog/data/catalog_models.dart';

/// Identité du magasin imprimée sur les documents (valeurs EFFECTIVES : base,
/// sinon variables d'environnement du serveur).
class StoreSettings {
  const StoreSettings(this.values);

  factory StoreSettings.fromJson(Map<String, dynamic> json) => StoreSettings({
    for (final field in fields) field: json[field] as String?,
  });

  /// Champs, dans l'ordre de l'écran.
  static const fields = ['name', 'address', 'phone', 'nif', 'rc', 'nis', 'ai'];

  final Map<String, String?> values;
}

/// Paramètres (P1 bis n°21h) : tarifs, taux de TVA, identité du magasin.
/// ADMIN seul — l'UI masque, le serveur refuse.
class SettingsApi {
  SettingsApi(this._dio);

  final Dio _dio;

  Future<StoreSettings> store() => guardApi(() async {
    final response = await _dio.get<Map<String, dynamic>>('/settings/store');
    return StoreSettings.fromJson(response.data!);
  });

  /// Champ vide : retour à la valeur du serveur (environnement).
  Future<StoreSettings> saveStore(Map<String, String?> changed) =>
      guardApi(() async {
        final response = await _dio.patch<Map<String, dynamic>>(
          '/settings/store',
          data: changed,
        );
        return StoreSettings.fromJson(response.data!);
      });

  /// Tarifs, inactifs compris.
  Future<List<PriceTier>> tiers() => guardApi(() async {
    final response = await _dio.get<List<dynamic>>(
      '/pricing/tiers',
      queryParameters: {'includeInactive': true},
    );
    return [
      for (final row in response.data!)
        PriceTier.fromJson(row as Map<String, dynamic>),
    ];
  });

  Future<void> saveTier(String? id, Map<String, Object?> fields) =>
      _save('/pricing/tiers', id, fields);

  Future<void> _save(String path, String? id, Map<String, Object?> fields) =>
      guardApi(() async {
        if (id == null) {
          await _dio.post<Object?>(path, data: fields);
        } else {
          await _dio.patch<Object?>('$path/$id', data: fields);
        }
      });
}

final settingsApiProvider = Provider<SettingsApi>(
  (ref) => SettingsApi(ref.watch(dioClientProvider).dio),
);

final storeSettingsProvider = FutureProvider.autoDispose<StoreSettings>(
  (ref) => ref.watch(settingsApiProvider).store(),
);

final settingsTiersProvider = FutureProvider.autoDispose<List<PriceTier>>(
  (ref) => ref.watch(settingsApiProvider).tiers(),
);
