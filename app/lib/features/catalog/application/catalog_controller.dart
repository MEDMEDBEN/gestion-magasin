import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';
import '../data/catalog_repository.dart';

/// Mise à jour du catalogue local depuis le serveur (delta).
///
/// Son échec n'empêche PAS d'afficher le catalogue déjà enregistré : l'écran
/// lit la base locale, cet état ne dit que « à jour » ou « pas pu se mettre à
/// jour » (lecture cache-first, docs/context.md).
///
/// Vit tant qu'un compte est connecté (la coquille l'écoute) et se relance à
/// CHAQUE connexion : un poste neuf a son catalogue sans passer par l'écran
/// Catalogue. Le serveur ne descend que le sous-ensemble visible du rôle
/// (coût d'achat et fournisseur masqués selon les droits).
class CatalogSyncController extends AsyncNotifier<void> {
  @override
  Future<void> build() {
    final userId = ref.watch(currentUserIdProvider);
    if (userId == null) return Future.value();
    return ref.read(catalogRepositoryProvider).pull();
  }

  /// Mise à jour à la demande (entrée en Vente, bouton « Actualiser »). Une
  /// synchro déjà en cours n'est pas doublée.
  Future<void> refresh() async {
    if (state.isLoading) return;
    if (ref.read(currentUserIdProvider) == null) return;
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(ref.read(catalogRepositoryProvider).pull);
  }
}

final catalogSyncProvider = AsyncNotifierProvider<CatalogSyncController, void>(
  CatalogSyncController.new,
);

/// Filtres de la liste des produits.
@immutable
class ProductFilter {
  const ProductFilter({
    this.search = '',
    this.categoryId,
    this.includeInactive = false,
  });

  final String search;
  final String? categoryId;
  final bool includeInactive;

  ProductFilter copyWith({
    String? search,
    ValueGetter<String?>? categoryId,
    bool? includeInactive,
  }) => ProductFilter(
    search: search ?? this.search,
    categoryId: categoryId != null ? categoryId() : this.categoryId,
    includeInactive: includeInactive ?? this.includeInactive,
  );
}

class ProductFilterController extends Notifier<ProductFilter> {
  @override
  ProductFilter build() => const ProductFilter();

  void setSearch(String term) => state = state.copyWith(search: term.trim());
  void setCategory(String? id) => state = state.copyWith(categoryId: () => id);
  void setIncludeInactive(bool value) =>
      state = state.copyWith(includeInactive: value);
}

final productFilterProvider =
    NotifierProvider.autoDispose<ProductFilterController, ProductFilter>(
      ProductFilterController.new,
    );

final categoriesProvider = StreamProvider.autoDispose<List<ProductCategory>>(
  (ref) => ref.watch(catalogRepositoryProvider).watchCategories(),
);

final locationsProvider = StreamProvider.autoDispose<List<StorageLocation>>(
  (ref) => ref.watch(catalogRepositoryProvider).watchLocations(),
);

final taxRatesProvider = StreamProvider.autoDispose<List<TaxRate>>(
  (ref) => ref.watch(catalogRepositoryProvider).watchTaxRates(),
);

/// Une catégorie choisie comme filtre inclut ses sous-catégories — même règle
/// que le serveur (`GET /products?categoryId=`).
Set<String> categoryWithChildren(String id, List<ProductCategory> categories) =>
    {
      id,
      for (final c in categories)
        if (c.parentId == id) c.id,
    };

/// Tous les produits actifs, sans filtre d'écran — pour les sélecteurs de
/// produit des autres features (perte, vente, réception…).
final activeProductsProvider = StreamProvider.autoDispose<List<Product>>(
  (ref) => ref.watch(catalogRepositoryProvider).watchProducts(),
);

/// Photo d'un produit, chargée À LA DEMANDE (jamais préchargée en masse,
/// docs/context.md) et gardée en mémoire pour la session. La clé versionnée
/// (`imageKey`) fait recharger dès qu'une nouvelle photo est posée.
final productImageProvider = FutureProvider.autoDispose
    .family<Uint8List, ({String productId, String imageKey})>((ref, photo) {
      ref.keepAlive();
      return ref.watch(catalogApiProvider).imageBytes(photo.productId);
    });

/// Choix d'une photo par l'utilisateur (galerie, ou fichier sur desktop),
/// compressée avant envoi. Remplaçable en test.
final pickProductPhotoProvider = Provider<Future<Uint8List?> Function()>(
  (ref) => () async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return null;
    return compute(compressProductPhoto, await file.readAsBytes());
  },
);

/// JPEG ≤ 1024 px de côté, qualité 80 : quelques centaines de ko, loin des 2 Mo
/// acceptés par le serveur. `null` si le fichier n'est pas une image lisible.
Uint8List? compressProductPhoto(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // Un fichier tronqué ou d'un autre format peut faire lever le décodeur.
    return null;
  }
  if (decoded == null) return null;
  final resized = decoded.width >= decoded.height
      ? (decoded.width > 1024 ? img.copyResize(decoded, width: 1024) : decoded)
      : (decoded.height > 1024
            ? img.copyResize(decoded, height: 1024)
            : decoded);
  return img.encodeJpg(resized, quality: 80);
}

/// Tarifs actifs (DETAIL, GROS…), lus en ligne pour le formulaire produit.
final priceTiersProvider = FutureProvider.autoDispose<List<PriceTier>>(
  (ref) => ref.watch(catalogApiProvider).priceTiers(),
);

final productsProvider = StreamProvider.autoDispose<List<Product>>((ref) {
  final filter = ref.watch(productFilterProvider);
  final categoryId = filter.categoryId;
  final categories = categoryId == null
      ? const <ProductCategory>[]
      : ref.watch(categoriesProvider).value ?? const <ProductCategory>[];
  return ref
      .watch(catalogRepositoryProvider)
      .watchProducts(
        search: filter.search,
        categoryIds: categoryId == null
            ? null
            : categoryWithChildren(categoryId, categories),
        includeInactive: filter.includeInactive,
      );
});

/// Écritures du catalogue — EN LIGNE uniquement (opérations d'administration,
/// aucune n'est créée hors-ligne). La réponse du serveur est enregistrée
/// localement tout de suite : l'écran n'attend pas le prochain delta.
class CatalogActions {
  CatalogActions(this._api, this._repository);

  final CatalogApi _api;
  final CatalogRepository _repository;

  /// `photo` : nouvelle photo (déjà compressée) ; `removePhoto` : la retirer.
  /// La photo part APRÈS l'enregistrement du produit (il faut son id).
  Future<Product> saveProduct(
    String? id,
    Map<String, Object?> fields, {
    Uint8List? photo,
    bool removePhoto = false,
    Map<String, int> prices = const {},
  }) async {
    var product = id == null
        ? await _api.createProduct(fields)
        : fields.isEmpty
        ? null
        : await _api.updateProduct(id, fields);
    final productId = product?.id ?? id!;
    if (photo != null) {
      product = await _api.uploadImage(productId, photo);
    } else if (removePhoto) {
      product = await _api.removeImage(productId);
    }
    // Prix modifiés, un tarif à la fois (chaque changement est tracé serveur).
    for (final entry in prices.entries) {
      product = await _api.setPrice(productId, entry.key, entry.value);
    }
    if (product == null) {
      throw StateError('saveProduct appelé sans aucun changement');
    }
    await _repository.saveAll(products: [product]);
    return product;
  }

  Future<ProductCategory> saveCategory(
    String? id,
    Map<String, Object?> fields,
  ) async {
    final category = id == null
        ? await _api.createCategory(fields)
        : await _api.updateCategory(id, fields);
    await _repository.saveAll(categories: [category]);
    return category;
  }

  Future<StorageLocation> saveLocation(
    String? id,
    Map<String, Object?> fields,
  ) async {
    final location = id == null
        ? await _api.createLocation(fields)
        : await _api.updateLocation(id, fields);
    await _repository.saveAll(locations: [location]);
    return location;
  }
}

final catalogActionsProvider = Provider<CatalogActions>(
  (ref) => CatalogActions(
    ref.watch(catalogApiProvider),
    ref.watch(catalogRepositoryProvider),
  ),
);

/// Champs modifiés entre deux versions d'un formulaire : n'envoie que ce qui a
/// bougé (un PATCH ne doit jamais réécrire ce que personne n'a touché).
Map<String, Object?> changedFields(
  Map<String, Object?> before,
  Map<String, Object?> after,
) => {
  for (final entry in after.entries)
    if (before[entry.key] != entry.value) entry.key: entry.value,
};
