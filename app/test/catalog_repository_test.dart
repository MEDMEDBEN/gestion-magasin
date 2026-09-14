import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/data/local/local_settings_store.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_api.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_repository.dart';

import 'support/catalog_fakes.dart';

/// Faux serveur de delta : sert des pages préparées et note les curseurs reçus.
class _PagedApi extends CatalogApi {
  _PagedApi(this.pages, {this.failAt}) : super(Dio());

  final List<CatalogChanges> pages;
  final int? failAt;
  final List<String?> cursors = [];

  @override
  Future<CatalogChanges> changes({String? cursor, int limit = 500}) async {
    cursors.add(cursor);
    final index = cursors.length - 1;
    if (index == failAt) {
      throw ApiException(statusCode: 0, message: 'hors ligne');
    }
    return pages[index];
  }
}

CatalogChanges _page(
  String cursor, {
  List<Product> products = const [],
  List<ProductCategory> categories = const [],
  bool hasMore = false,
}) => CatalogChanges(
  products: products,
  categories: categories,
  locations: const [],
  taxRates: const [],
  cursor: cursor,
  hasMore: hasMore,
);

void main() {
  late AppDatabase db;
  late LocalSettingsStore settings;

  setUp(() {
    db = AppDatabase.forTesting();
    settings = LocalSettingsStore(db);
  });
  tearDown(() => db.close());

  test(
    'descend toutes les pages, puis ne redemande que depuis le dernier curseur',
    () async {
      final api = _PagedApi([
        _page(
          'c1',
          products: [product(id: 'p1', name: 'Câble')],
          hasMore: true,
        ),
        _page(
          'c2',
          products: [product(id: 'p2', name: 'Disjoncteur')],
        ),
        _page('c3'),
      ]);
      final repo = CatalogRepository(db, settings, api);

      await repo.pull();
      expect(api.cursors, [null, 'c1']);
      expect((await repo.watchProducts().first).map((p) => p.id), ['p1', 'p2']);

      await repo.pull();
      expect(api.cursors.last, 'c2');
    },
  );

  test(
    'une coupure au milieu garde les pages déjà reçues ET leur curseur',
    () async {
      final api = _PagedApi([
        _page('c1', products: [product(id: 'p1')], hasMore: true),
        _page('c2'),
      ], failAt: 1);
      final repo = CatalogRepository(db, settings, api);

      await expectLater(repo.pull(), throwsA(isA<ApiException>()));
      expect(await settings.read(CatalogRepository.cursorKey), 'c1');
      expect(await repo.watchProducts().first, hasLength(1));
    },
  );

  test(
    'un produit modifié remplace sa version locale (pas de doublon)',
    () async {
      final repo = CatalogRepository(db, settings, _PagedApi(const []));
      await repo.saveAll(
        products: [product(id: 'p1', name: 'Ancien nom')],
      );
      await repo.saveAll(
        products: [product(id: 'p1', name: 'Nouveau nom')],
      );

      final products = await repo.watchProducts().first;
      expect(products.single.name, 'Nouveau nom');
    },
  );

  test(
    'une version PLUS ANCIENNE (page de delta en retard) n’écrase pas la récente',
    () async {
      final repo = CatalogRepository(db, settings, _PagedApi(const []));
      await repo.saveAll(
        products: [
          product(
            id: 'p1',
            name: 'Enregistré par l’admin',
          ).copyWith(updatedAt: DateTime.utc(2026, 9, 14, 12)),
        ],
      );
      await repo.saveAll(
        products: [
          product(
            id: 'p1',
            name: 'Page partie avant',
          ).copyWith(updatedAt: DateTime.utc(2026, 9, 14, 11)),
        ],
      );
      expect(
        (await repo.watchProducts().first).single.name,
        'Enregistré par l’admin',
      );
    },
  );

  test('recherche sans accents : « cable » trouve « Câble »', () async {
    final repo = CatalogRepository(db, settings, _PagedApi(const []));
    await repo.saveAll(
      products: [product(id: 'p1', name: 'Câble électrique')],
    );
    expect(
      await repo.watchProducts(search: 'cable electrique').first,
      hasLength(1),
    );
    expect(await repo.watchProducts(search: 'CÂBLE').first, hasLength(1));
  });

  test(
    'recherche nom/référence/marque/code, filtre catégorie, inactifs masqués',
    () async {
      final repo = CatalogRepository(db, settings, _PagedApi(const []));
      await repo.saveAll(
        products: [
          product(
            id: 'p1',
            name: 'Câble souple',
            sku: 'CAB-3G25',
            categoryId: 'cat',
          ),
          product(
            id: 'p2',
            name: 'Disjoncteur',
            brand: 'Legrand',
            barcode: '4006381333931',
          ),
          product(id: 'p3', name: 'Câble rigide', isActive: false),
        ],
      );

      Future<List<String>> ids({
        String search = '',
        Set<String>? categories,
        bool inactive = false,
      }) async =>
          (await repo
                  .watchProducts(
                    search: search,
                    categoryIds: categories,
                    includeInactive: inactive,
                  )
                  .first)
              .map((p) => p.id)
              .toList();

      expect(await ids(search: 'câble'), ['p1']);
      // Triés par nom : « Câble rigide » avant « Câble souple ».
      expect(await ids(search: 'câble', inactive: true), ['p3', 'p1']);
      expect(await ids(search: 'cab-3g'), ['p1']);
      expect(await ids(search: 'legrand'), ['p2']);
      expect(await ids(search: '4006381'), ['p2']);
      expect(await ids(categories: {'cat'}), ['p1']);
      // « % » est cherché tel quel, pas comme joker SQL.
      expect(await ids(search: '%'), isEmpty);
    },
  );

  test(
    'une base v3 migre en v4 : colonne de version ajoutée, lignes gardées',
    () async {
      final executor = NativeDatabase.memory(
        setup: (raw) {
          raw.execute('''
          CREATE TABLE pending_mutations (
            client_mutation_id TEXT NOT NULL PRIMARY KEY, author_user_id TEXT NULL,
            device_id TEXT NOT NULL, operation_type TEXT NOT NULL, payload TEXT NOT NULL,
            device_timestamp INTEGER NOT NULL, status INTEGER NOT NULL DEFAULT 0,
            rejection_code TEXT NULL, rejection_reason TEXT NULL, entity_id TEXT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0, last_attempt_at INTEGER NULL,
            created_at INTEGER NOT NULL
          )''');
          raw.execute(
            'CREATE TABLE local_settings (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
          );
          raw.execute('''
          CREATE TABLE catalog_entries (
            kind TEXT NOT NULL, id TEXT NOT NULL, label TEXT NOT NULL,
            search_text TEXT NOT NULL, parent_id TEXT NULL,
            is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)), json TEXT NOT NULL,
            PRIMARY KEY (kind, id)
          )''');
          raw.execute(
            "INSERT INTO catalog_entries VALUES ('product', 'p1', 'ancien', 'ancien', NULL, 1, "
            "'{\"id\":\"p1\"}')",
          );
          raw.execute('PRAGMA user_version = 3');
        },
      );
      final migrated = AppDatabase(executor);
      addTearDown(migrated.close);
      final repo = CatalogRepository(
        migrated,
        LocalSettingsStore(migrated),
        _PagedApi(const []),
      );

      // Ligne v3 sans version : la première version reçue la remplace.
      await repo.saveAll(
        products: [product(id: 'p1', name: 'Nouveau')],
      );
      expect((await repo.watchProducts().first).single.name, 'Nouveau');
    },
  );

  test('une base v2 migre en v3 : la table du catalogue est créée', () async {
    final executor = NativeDatabase.memory(
      setup: (raw) {
        raw.execute('''
          CREATE TABLE pending_mutations (
            client_mutation_id TEXT NOT NULL PRIMARY KEY,
            author_user_id TEXT NULL,
            device_id TEXT NOT NULL,
            operation_type TEXT NOT NULL,
            payload TEXT NOT NULL,
            device_timestamp INTEGER NOT NULL,
            status INTEGER NOT NULL DEFAULT 0,
            rejection_code TEXT NULL,
            rejection_reason TEXT NULL,
            entity_id TEXT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_attempt_at INTEGER NULL,
            created_at INTEGER NOT NULL
          )''');
        raw.execute(
          'CREATE TABLE local_settings (key TEXT NOT NULL PRIMARY KEY, '
          'value TEXT NOT NULL)',
        );
        raw.execute("INSERT INTO local_settings VALUES ('theme', 'dark')");
        raw.execute('PRAGMA user_version = 2');
      },
    );
    final migrated = AppDatabase(executor);
    addTearDown(migrated.close);
    final repo = CatalogRepository(
      migrated,
      LocalSettingsStore(migrated),
      _PagedApi(const []),
    );

    await repo.saveAll(products: [product(id: 'p1')]);
    expect(await repo.watchProducts().first, hasLength(1));
    expect(await LocalSettingsStore(migrated).read('theme'), 'dark');
  });
}
