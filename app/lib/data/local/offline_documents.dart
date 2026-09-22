import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/api_exception.dart';
import '../../core/providers.dart';
import 'document_cache.dart';

/// Une liste de travail et SA PROVENANCE : `cachedAt` non nul = elle vient de
/// la copie locale, datée. L'écran l'affiche ; la fraîcheur ne se déduit jamais
/// de l'état du réseau (qui peut revenir sans que la liste soit relue).
class CachedList<T> {
  const CachedList(this.items, {this.cachedAt});

  final List<T> items;
  final DateTime? cachedAt;

  bool get fromCache => cachedAt != null;
}

/// Lit la liste EN LIGNE et la garde sur l'appareil ; sans réseau, rend la
/// DERNIÈRE connue de ce compte (P1 n°14 : au dépôt, l'écran doit s'ouvrir).
///
/// Relue au RETOUR du réseau (`serverReachableProvider` surveillé) : sans cela,
/// l'écran garderait la copie de la veille en la donnant pour fraîche.
/// Aucune écriture ne passe par ici.
Future<CachedList<T>> onlineOrCached<T>(
  Ref ref,
  DocumentKind kind, {
  required Future<List<T>> Function() fetch,
  required Map<String, dynamic> Function(T) toJson,
  required T Function(Map<String, dynamic>) fromJson,
}) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return CachedList<T>(const []);
  // Coupure ET retour : les deux relisent la liste.
  ref.watch(serverReachableProvider);
  final cache = ref.watch(documentCacheProvider);
  try {
    final items = await fetch();
    await cache.save(userId, kind, items.map(toJson).toList());
    return CachedList<T>(items);
  } on ApiException catch (error) {
    if (!error.isOffline) rethrow;
    final cached = await cache.read(userId, kind);
    // Rien de gardé (jamais descendu, ou copie trop vieille) : l'écran dit
    // « hors ligne ». Une liste VIDE déjà descendue, elle, s'ouvre : « rien à
    // faire aujourd'hui » est une réponse, pas une panne.
    if (cached.cachedAt == null) rethrow;
    return CachedList<T>(
      cached.documents.map(fromJson).toList(),
      cachedAt: cached.cachedAt,
    );
  }
}
