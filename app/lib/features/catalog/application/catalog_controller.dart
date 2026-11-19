import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/offline_write.dart';
import '../../../core/providers.dart';
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';
import '../data/catalog_repository.dart';
import '../../stock/application/stock_controller.dart';

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
    // Les tarifs descendent avec le catalogue : la vente hors ligne en a
    // besoin, même si l'écran Vente n'a jamais été ouvert en ligne.
    loadPriceTiers(ref).ignore();
    return ref.read(catalogRepositoryProvider).pull();
  }

  /// Mise à jour à la demande (entrée en Vente, bouton « Actualiser »). Une
  /// synchro déjà en cours n'est pas doublée.
  Future<void> refresh() async {
    if (state.isLoading) return;
    if (ref.read(currentUserIdProvider) == null) return;
    state = const AsyncLoading<void>();
    final result = await AsyncValue.guard(
      ref.read(catalogRepositoryProvider).pull,
    );
    // L'utilisateur a pu se déconnecter (ou l'application se fermer) pendant la
    // synchro : écrire l'état d'un provider détruit lève une exception.
    if (!ref.mounted) return;
    state = result;
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

/// Recherche DEMANDÉE avant d'ouvrir Catalogue ou Stock (assistant :
/// « chof câble »). Gardée hors du filtre, qui est libéré quand aucun écran ne
/// l'écoute ; l'écran ouvert la reprend une fois (`take`).
class RequestedSearch extends Notifier<String?> {
  @override
  String? build() => null;

  void ask(String text) => state = text;

  String? take() {
    final text = state;
    state = null;
    return text;
  }
}

final requestedSearchProvider = NotifierProvider<RequestedSearch, String?>(
  RequestedSearch.new,
);

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

/// Produits cochés au catalogue (export, étiquettes) ; `null` = pas en mode
/// sélection (2026-10-05).
///
/// Garde les PRODUITS cochés, pas seulement leurs ids : la sélection traverse
/// les recherches (un produit coché puis masqué reste exporté, audit du
/// 2026-10-06).
class ProductSelection extends Notifier<Map<String, Product>?> {
  @override
  Map<String, Product>? build() => null;

  void start() => state = <String, Product>{};
  void stop() => state = null;

  void toggle(Product product) {
    final current = {...?state};
    if (current.remove(product.id) == null) current[product.id] = product;
    state = current;
  }

  /// AJOUTE ces produits à la sélection.
  void addAll(Iterable<Product> products) =>
      state = {...?state, for (final p in products) p.id: p};
}

/// Produit enregistré, mais pas sa photo : le formulaire se ferme sur le
/// produit et le DIT (message du serveur ou du réseau).
class PhotoNotSaved implements Exception {
  const PhotoNotSaved(this.product, this.cause);

  final Product product;
  final ApiException cause;

  String get message =>
      '${product.name} enregistré, mais la photo n’a pas pu être envoyée : '
      '${cause.userMessage}';
}

final productSelectionProvider =
    NotifierProvider.autoDispose<ProductSelection, Map<String, Product>?>(
      ProductSelection.new,
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

/// Tarifs actifs (DETAIL, GROS…). Lus en ligne, et MÉMORISÉS sur l'appareil :
/// hors ligne, la vente en a besoin (tarif par défaut → prix des tuiles et du
/// ticket) — sans eux, tout produit passait « sans prix » et l'encaissement
/// était bloqué (retour terrain du 2026-10-11). Jamais lu : l'erreur remonte.
final priceTiersProvider = FutureProvider.autoDispose<List<PriceTier>>(
  loadPriceTiers,
);

/// Lit les tarifs en ligne et les mémorise ; hors ligne, rend la mémoire.
Future<List<PriceTier>> loadPriceTiers(Ref ref) async {
  final settings = ref.read(localSettingsStoreProvider);
  const memoryKey = 'price-tiers';
  try {
    final tiers = await ref.read(catalogApiProvider).priceTiers();
    await settings.write(
      memoryKey,
      jsonEncode([for (final t in tiers) t.toJson()]),
    );
    return tiers;
  } on ApiException catch (error) {
    final known = error.isOffline ? await settings.read(memoryKey) : null;
    if (known == null) rethrow;
    return [
      for (final row in jsonDecode(known) as List<dynamic>)
        PriceTier.fromJson(row as Map<String, dynamic>),
    ];
  }
}

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
  CatalogActions(
    this._api,
    this._repository,
    this._onStockChanged, [
    this._ref,
  ]);

  /// Pour écrire hors ligne (file de synchro) ; absent dans certains tests.
  final Ref? _ref;

  final CatalogApi _api;
  final CatalogRepository _repository;

  /// Un produit créé avec son stock initial : les niveaux affichés (Vente,
  /// Stock) sont relus, sinon il resterait « Rupture » jusqu'au rechargement.
  final void Function() _onStockChanged;

  /// `photo` : nouvelle photo (déjà compressée) ; `removePhoto` : la retirer.
  /// La photo part APRÈS l'enregistrement du produit (il faut son id).
  Future<Product> saveProduct(
    String? id,
    Map<String, Object?> fields, {
    Uint8List? photo,
    bool removePhoto = false,
    Map<String, int> prices = const {},
  }) async {
    // Création : en ligne, ou EN FILE hors ligne (demande MEDMEDBEN du
    // 2026-11-15) — le produit est utilisable tout de suite sur ce poste.
    if (id == null && _ref != null) {
      final created = await _createOnlineOrQueue(_ref, fields, prices);
      if (created.pending) return created.product;
      // En ligne : la photo suit, comme avant.
      return _afterCreate(created.product, photo: photo);
    }
    var product = id == null
        ? await _api.createProduct(fields)
        : fields.isEmpty
        ? null
        : await _api.updateProduct(id, fields);
    final productId = product?.id ?? id!;
    // La photo part APRÈS le produit : si elle échoue, le produit est déjà
    // créé — on l'enregistre quand même et on DIT que seule la photo manque
    // (sinon un nouvel essai recréerait le produit en double).
    ApiException? photoError;
    try {
      if (photo != null) {
        product = await _api.uploadImage(productId, photo);
      } else if (removePhoto) {
        product = await _api.removeImage(productId);
      }
    } on ApiException catch (error) {
      photoError = error;
    }
    // Prix modifiés, un tarif à la fois (chaque changement est tracé serveur).
    for (final entry in prices.entries) {
      product = await _api.setPrice(productId, entry.key, entry.value);
    }
    product ??= photoError != null ? await _api.product(productId) : null;
    if (product == null) {
      throw StateError('saveProduct appelé sans aucun changement');
    }
    await _repository.saveAll(products: [product]);
    if (fields.containsKey('initialStock')) _onStockChanged();
    if (photoError != null) throw PhotoNotSaved(product, photoError);
    return product;
  }

  /// UNE opération (`PRODUCT`) : produit + prix. En ligne : `POST /products`
  /// puis les prix ; hors ligne : en file, et une copie LOCALE marquée « en
  /// attente » (date ancienne : la version du serveur la remplacera).
  Future<({Product product, bool pending})> _createOnlineOrQueue(
    Ref ref,
    Map<String, Object?> fields,
    Map<String, int> prices,
  ) async {
    final intent = 'product:${ref.read(uuidProvider).v4()}';
    final outcome = await writeOnlineOrQueue<Product>(
      ref,
      intent: intent,
      operationType: 'PRODUCT',
      payload: (key) => {
        for (final e in fields.entries)
          if (e.value != null) e.key: e.value,
        'id': key,
        if (prices.isNotEmpty)
          'prices': [
            for (final e in prices.entries)
              {'priceTierId': e.key, 'priceHt': e.value},
          ],
      },
      online: (body) async {
        var product = await _api.createProduct({...body}..remove('prices'));
        for (final e in prices.entries) {
          product = await _api.setPrice(product.id, e.key, e.value);
        }
        return product;
      },
    );
    switch (outcome) {
      case Applied(:final value):
        await _repository.saveAll(products: [value]);
        if (fields.containsKey('initialStock')) _onStockChanged();
        return (product: value, pending: false);
      case Queued(:final clientMutationId):
        final local = Product.fromJson({
          for (final e in fields.entries)
            if (e.value != null) e.key: e.value,
          'id': clientMutationId,
          'barcode': fields['barcode'] ?? '',
          'minThreshold': fields['minThreshold'] ?? '0',
          'safetyStock': '0',
          'allowBackorder': fields['allowBackorder'] ?? false,
          'isActive': true,
          'updatedAt': DateTime.utc(2000).toIso8601String(),
          'prices': [
            for (final e in prices.entries)
              {'priceTierId': e.key, 'priceHt': e.value},
          ],
        });
        await _repository.saveAll(products: [local]);
        return (product: local, pending: true);
    }
  }

  Future<Product> _afterCreate(Product product, {Uint8List? photo}) async {
    if (photo == null) return product;
    try {
      final withPhoto = await _api.uploadImage(product.id, photo);
      await _repository.saveAll(products: [withPhoto]);
      return withPhoto;
    } on ApiException catch (error) {
      throw PhotoNotSaved(product, error);
    }
  }

  /// Relit DU SERVEUR des produits qui viennent de changer (achat : nouveau
  /// prix d'achat, « prix à revoir », « à répartir ») et les pose dans le
  /// cache — sans attendre la descente delta, qui ne livre un produit qu'un
  /// peu après sa modification (2026-11-19). Une erreur n'empêche rien.
  Future<void> refreshProducts(Iterable<String> ids) async {
    final fresh = <Product>[];
    for (final id in ids.toSet()) {
      try {
        fresh.add(await _api.product(id));
      } on Object {
        // Hors ligne ou produit introuvable : la synchro le rattrapera.
      }
    }
    if (fresh.isNotEmpty) await _repository.saveAll(products: fresh);
    _onStockChanged();
  }

  /// « Réparti » (2026-11-19) : lève le repère « à répartir ».
  Future<Product> splitDone(String id) async {
    final product = await _api.productAction(id, 'split-done');
    await _repository.saveAll(products: [product]);
    _onStockChanged();
    return product;
  }

  /// « Garder le prix » (2026-11-19) : le prix de vente reste malgré le
  /// nouveau prix d'achat — le repère « prix à revoir » est levé.
  Future<Product> keepPrice(String id) async {
    final product = await _api.productAction(id, 'keep-price');
    await _repository.saveAll(products: [product]);
    return product;
  }

  /// Effacement DÉFINITIF (serveur PUIS cache de ce poste) d'un produit sans
  /// historique. Les autres postes l'oublient à leur prochaine synchro.
  /// 409 (il a un historique) : remonte tel quel, l'écran propose de le
  /// désactiver.
  Future<void> deleteProduct(String id) async {
    await _api.deleteProduct(id);
    await _repository.forget(CatalogKind.product, id);
    _onStockChanged();
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
    () => ref.invalidate(stockByProductProvider),
    ref,
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
