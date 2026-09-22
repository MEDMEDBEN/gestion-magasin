import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/local/app_database.dart';
import '../../../data/local/local_settings_store.dart';
import 'catalog_api.dart';
import 'catalog_models.dart';

/// Nature d'une ligne de `CatalogEntries`.
abstract final class CatalogKind {
  static const product = 'product';
  static const category = 'category';
  static const location = 'location';
  static const taxRate = 'taxRate';
}

/// Catalogue local, lu **cache-first** (docs/context.md : catalogue complet en
/// local, rafraîchi par delta). L'écran lit TOUJOURS la base locale ; le réseau
/// ne sert qu'à la mettre à jour.
class CatalogRepository {
  CatalogRepository(this._db, this._settings, this._api);

  static const cursorKey = 'catalog.cursor';

  final AppDatabase _db;
  final LocalSettingsStore _settings;
  final CatalogApi _api;

  /// Descend tout ce qui a changé depuis le dernier curseur, page par page.
  /// Chaque page est écrite AVEC son curseur dans une transaction : une coupure
  /// au milieu reprend exactement là où elle s'est arrêtée, sans trou.
  Future<void> pull() async {
    var cursor = await _settings.read(cursorKey);
    while (true) {
      final page = await _api.changes(cursor: cursor);
      await _db.transaction(() async {
        await saveAll(
          products: page.products,
          categories: page.categories,
          locations: page.locations,
          taxRates: page.taxRates,
        );
        await _settings.write(cursorKey, page.cursor);
      });
      cursor = page.cursor;
      if (!page.hasMore) return;
    }
  }

  /// Écrit localement des ressources reçues du serveur (delta, ou réponse d'une
  /// création/modification — affichée tout de suite, sans attendre le delta).
  Future<void> saveAll({
    List<Product> products = const [],
    List<ProductCategory> categories = const [],
    List<StorageLocation> locations = const [],
    List<TaxRate> taxRates = const [],
  }) {
    final rows = [
      for (final p in products)
        _row(
          CatalogKind.product,
          p.id,
          label: p.name,
          search: [p.name, p.sku, p.brand, p.barcode],
          parentId: p.categoryId,
          isActive: p.isActive,
          updatedAt: p.updatedAt,
          // Le fournisseur jamais sur le disque (base locale partagée par les
          // comptes du poste, non chiffrée ; le vendeur n'y a pas accès). Le
          // coût, lui, y est : les TROIS rôles le voient depuis la décision
          // du 2026-09-22 — c'est le plancher du prix modifiable, hors ligne
          // compris (docs/permissions.md).
          json: p.copyWith(mainSupplierId: null).toJson(),
        ),
      for (final c in categories)
        _row(
          CatalogKind.category,
          c.id,
          label: c.name,
          search: [c.name],
          parentId: c.parentId,
          isActive: c.isActive,
          updatedAt: c.updatedAt,
          json: c.toJson(),
        ),
      for (final l in locations)
        _row(
          CatalogKind.location,
          l.id,
          label: l.code,
          search: [l.code, l.name],
          parentId: l.parentId,
          isActive: l.isActive,
          updatedAt: l.updatedAt,
          json: l.toJson(),
        ),
      for (final t in taxRates)
        _row(
          CatalogKind.taxRate,
          t.id,
          label: t.name,
          search: [t.code, t.name],
          isActive: t.isActive,
          updatedAt: t.updatedAt,
          json: t.toJson(),
        ),
    ];
    return _db.batch((batch) {
      for (final row in rows) {
        batch.insert(
          _db.catalogEntries,
          row,
          onConflict: DoUpdate.withExcluded(
            (old, excluded) => row,
            // Jamais de retour en arrière : une version plus ancienne est ignorée.
            where: ($CatalogEntriesTable old, $CatalogEntriesTable excluded) =>
                old.updatedAt.isNull() |
                old.updatedAt.isSmallerOrEqual(excluded.updatedAt),
          ),
        );
      }
    });
  }

  /// Produits filtrés, triés par nom.
  /// ponytail: tout le résultat est chargé (catalogue d'un seul magasin, quelques
  /// milliers de lignes) ; passer à `limit/offset` si la liste devient lente.
  Stream<List<Product>> watchProducts({
    String search = '',
    Set<String>? categoryIds,
    bool includeInactive = false,
  }) {
    final query = _db.select(_db.catalogEntries)
      ..where((t) => t.kind.equals(CatalogKind.product))
      ..orderBy([(t) => OrderingTerm.asc(t.label)]);
    final term = foldForSearch(search.trim());
    if (term.isNotEmpty) {
      query.where(
        (t) => t.searchText.like('%${_escapeLike(term)}%', escapeChar: r'\'),
      );
    }
    if (categoryIds != null) query.where((t) => t.parentId.isIn(categoryIds));
    if (!includeInactive) query.where((t) => t.isActive.equals(true));
    return query.watch().map(
      (rows) => [for (final row in rows) Product.fromJson(_decode(row))],
    );
  }

  Stream<List<ProductCategory>> watchCategories() =>
      _watchAll(CatalogKind.category, ProductCategory.fromJson);

  Stream<List<StorageLocation>> watchLocations() =>
      _watchAll(CatalogKind.location, StorageLocation.fromJson);

  Stream<List<TaxRate>> watchTaxRates() =>
      _watchAll(CatalogKind.taxRate, TaxRate.fromJson);

  /// Le catalogue a-t-il déjà été descendu au moins une fois sur ce poste ?
  Future<bool> hasCursor() async => await _settings.read(cursorKey) != null;

  Stream<List<T>> _watchAll<T>(
    String kind,
    T Function(Map<String, dynamic>) decode,
  ) {
    final query = _db.select(_db.catalogEntries)
      ..where((t) => t.kind.equals(kind))
      ..orderBy([(t) => OrderingTerm.asc(t.label)]);
    return query.watch().map(
      (rows) => [for (final row in rows) decode(_decode(row))],
    );
  }

  static CatalogEntriesCompanion _row(
    String kind,
    String id, {
    required String label,
    required List<String?> search,
    String? parentId,
    required bool isActive,
    required DateTime updatedAt,
    required Map<String, dynamic> json,
  }) {
    return CatalogEntriesCompanion.insert(
      kind: kind,
      id: id,
      label: label.toLowerCase(),
      searchText: foldForSearch(search.whereType<String>().join(' ')),
      parentId: Value(parentId),
      isActive: isActive,
      updatedAt: Value(updatedAt),
      json: jsonEncode(json),
    );
  }

  static Map<String, dynamic> _decode(CatalogEntry row) =>
      jsonDecode(row.json) as Map<String, dynamic>;

  static String _escapeLike(String term) =>
      term.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}');
}

/// Minuscules sans accents : « cable » trouve « Câble » au comptoir.
String foldForSearch(String text) {
  const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
  final lower = text.toLowerCase();
  final buffer = StringBuffer();
  for (final char in lower.split('')) {
    final index = from.indexOf(char);
    buffer.write(index < 0 ? char : to[index]);
  }
  return buffer.toString();
}

final catalogRepositoryProvider = Provider<CatalogRepository>(
  (ref) => CatalogRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(localSettingsStoreProvider),
    ref.watch(catalogApiProvider),
  ),
);
