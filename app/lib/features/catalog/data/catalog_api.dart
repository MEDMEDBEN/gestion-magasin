import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'catalog_models.dart';

/// Accès réseau au catalogue. Aucune logique métier ici.
///
/// Lecture : tous les rôles (`product.read`). Écriture : produits et catégories
/// ADMIN (`product.write`), emplacements ADMIN + MAGASINIER (`location.manage`)
/// — l'UI masque, le serveur refuse.
class CatalogApi {
  CatalogApi(this._dio);

  final Dio _dio;

  Future<CatalogChanges> changes({String? cursor, int limit = 500}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/catalog/changes',
        queryParameters: {'limit': limit, 'cursor': ?cursor},
      );
      return CatalogChanges.fromJson(response.data!);
    });
  }

  /// `fields` : UNIQUEMENT les champs saisis ; sans `barcode`, le serveur
  /// génère un code interne unique (règle 15).
  Future<Product> createProduct(Map<String, Object?> fields) =>
      _send('POST', '/products', fields, Product.fromJson);

  /// N'envoie que les champs modifiés — `null` retire un rattachement.
  Future<Product> updateProduct(String id, Map<String, Object?> changes) =>
      _send('PATCH', '/products/$id', changes, Product.fromJson);

  /// Photo déjà compressée par l'app (JPEG ≤ 1024 px). Le serveur vérifie le
  /// type sur le contenu et renvoie le produit avec sa nouvelle `imageKey`.
  Future<List<PriceTier>> priceTiers() {
    return guardApi(() async {
      final response = await _dio.get<List<dynamic>>('/pricing/tiers');
      return [
        for (final row in response.data!)
          PriceTier.fromJson(row as Map<String, dynamic>),
      ];
    });
  }

  /// Prix HT en centimes — ADMIN seul (le serveur relit ses droits en base).
  Future<Product> setPrice(String productId, String priceTierId, int priceHt) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/products/$productId/prices',
        data: {'priceTierId': priceTierId, 'priceHt': priceHt},
      );
      return Product.fromJson(response.data!);
    });
  }

  Future<Product> uploadImage(String productId, Uint8List jpeg) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/products/$productId/image',
        data: FormData.fromMap({
          'image': MultipartFile.fromBytes(jpeg, filename: 'photo.jpg'),
        }),
      );
      return Product.fromJson(response.data!);
    });
  }

  Future<Product> removeImage(String productId) {
    return guardApi(() async {
      final response = await _dio.delete<Map<String, dynamic>>(
        '/products/$productId/image',
      );
      return Product.fromJson(response.data!);
    });
  }

  /// Octets de la photo, par la route authentifiée (le stockage est privé).
  Future<Uint8List> imageBytes(String productId) {
    return guardApi(() async {
      final response = await _dio.get<List<int>>(
        '/products/$productId/image',
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data!);
    });
  }

  Future<ProductCategory> createCategory(Map<String, Object?> fields) =>
      _send('POST', '/categories', fields, ProductCategory.fromJson);

  Future<ProductCategory> updateCategory(
    String id,
    Map<String, Object?> changes,
  ) => _send('PATCH', '/categories/$id', changes, ProductCategory.fromJson);

  Future<StorageLocation> createLocation(Map<String, Object?> fields) =>
      _send('POST', '/locations', fields, StorageLocation.fromJson);

  Future<StorageLocation> updateLocation(
    String id,
    Map<String, Object?> changes,
  ) => _send('PATCH', '/locations/$id', changes, StorageLocation.fromJson);

  Future<T> _send<T>(
    String method,
    String path,
    Map<String, Object?> data,
    T Function(Map<String, dynamic>) decode,
  ) {
    return guardApi(() async {
      final response = await _dio.request<Map<String, dynamic>>(
        path,
        data: data,
        options: Options(method: method),
      );
      return decode(response.data!);
    });
  }
}

final catalogApiProvider = Provider<CatalogApi>(
  (ref) => CatalogApi(ref.watch(dioClientProvider).dio),
);
