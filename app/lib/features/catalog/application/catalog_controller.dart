import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/catalog_api.dart';
import '../data/catalog_models.dart';
import '../data/catalog_repository.dart';

/// Mise à jour du catalogue local depuis le serveur (delta).
///
/// Son échec n'empêche PAS d'afficher le catalogue déjà enregistré : l'écran
/// lit la base locale, cet état ne dit que « à jour » ou « pas pu se mettre à
/// jour » (lecture cache-first, docs/context.md).
class CatalogSyncController extends AsyncNotifier<void> {
  @override
  Future<void> build() => ref.read(catalogRepositoryProvider).pull();

  Future<void> refresh() async {
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(ref.read(catalogRepositoryProvider).pull);
  }
}

final catalogSyncProvider =
    AsyncNotifierProvider.autoDispose<CatalogSyncController, void>(
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

  Future<Product> saveProduct(String? id, Map<String, Object?> fields) async {
    final product = id == null
        ? await _api.createProduct(fields)
        : await _api.updateProduct(id, fields);
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
