import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/data/local/document_cache.dart';
import 'package:gestion_magasin/data/local/offline_documents.dart';

/// Écrans mobiles du dépôt (P1 n°14) : ils doivent s'OUVRIR sans réseau, sur la
/// dernière liste connue — datée, jamais présentée comme fraîche.
void main() {
  late AppDatabase db;
  late DocumentCache cache;

  setUp(() {
    db = AppDatabase.forTesting();
    cache = DocumentCache(db);
  });
  tearDown(() => db.close());

  test(
    'la liste gardée est celle du COMPTE : rien ne fuit sur un poste partagé',
    () async {
      await cache.save('magasinier', DocumentKind.transfer, [
        {'id': 't1', 'number': 'TRF-2026-00001'},
      ]);
      await cache.save('vendeur', DocumentKind.transfer, [
        {'id': 't2', 'number': 'TRF-2026-00002'},
      ]);

      final mine = await cache.read('magasinier', DocumentKind.transfer);
      expect(mine.documents.single['number'], 'TRF-2026-00001');
      expect(mine.cachedAt, isNotNull);
      final none = await cache.read('admin', DocumentKind.transfer);
      expect(none.documents, isEmpty);
      expect(none.cachedAt, isNull, reason: 'rien de gardé pour ce compte');
    },
  );

  test(
    'une liste lue en ligne REMPLACE la précédente (rien de fantôme)',
    () async {
      await cache.save('m', DocumentKind.inventory, [
        {'id': 'i1'},
        {'id': 'i2'},
      ]);
      await cache.save('m', DocumentKind.inventory, [
        {'id': 'i2'},
      ]);

      final kept = await cache.read('m', DocumentKind.inventory);
      expect(kept.documents.map((d) => d['id']), ['i2']);
    },
  );

  test('une liste VIDE gardée s’ouvre hors ligne : « rien à faire » est une '
      'réponse, pas une panne', () async {
    await cache.save('m', DocumentKind.transfer, const []);

    final kept = await cache.read('m', DocumentKind.transfer);
    expect(kept.documents, isEmpty);
    expect(kept.cachedAt, isNotNull, reason: 'la liste a bien été descendue');
  });

  test('l’ORDRE du serveur est conservé (récents d’abord)', () async {
    await cache.save('m', DocumentKind.transfer, [
      {'id': 'zzz', 'number': 'TRF-3'},
      {'id': 'aaa', 'number': 'TRF-2'},
      {'id': 'mmm', 'number': 'TRF-1'},
    ]);

    final kept = await cache.read('m', DocumentKind.transfer);
    expect(kept.documents.map((d) => d['number']), ['TRF-3', 'TRF-2', 'TRF-1']);
  });

  test('copie trop vieille : effacée et traitée comme inexistante', () async {
    await cache.save(
      'm',
      DocumentKind.transfer,
      [
        {'id': 't1'},
      ],
      at: DateTime.now().toUtc().subtract(DocumentCache.maxAge * 2),
    );

    final kept = await cache.read('m', DocumentKind.transfer);
    expect(kept.cachedAt, isNull);
    expect(kept.documents, isEmpty);
    // Effacée pour de bon : une seconde lecture ne la ressuscite pas.
    expect((await cache.read('m', DocumentKind.transfer)).cachedAt, isNull);
  });

  test(
    'déconnexion : tout ce qui est gardé pour CE compte est effacé',
    () async {
      await cache.save('m', DocumentKind.transfer, [
        {'id': 't1'},
      ]);
      await cache.save('v', DocumentKind.transfer, [
        {'id': 't2'},
      ]);

      await cache.clear('m');

      expect((await cache.read('m', DocumentKind.transfer)).cachedAt, isNull);
      expect(
        (await cache.read('v', DocumentKind.transfer)).documents,
        hasLength(1),
        reason: 'la copie de l’autre compte n’est pas touchée',
      );
    },
  );

  group('onlineOrCached', () {
    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          currentUserIdProvider.overrideWithValue('m'),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    /// Appel DIRECT de l'aide (un `FutureProvider` de test masquerait l'erreur
    /// derrière son propre cycle de vie).
    Future<CachedList<String>> run(
      ProviderContainer c,
      Future<List<String>> Function() fetch,
    ) => c.read(
      Provider<Future<CachedList<String>>>(
        (ref) => onlineOrCached<String>(
          ref,
          DocumentKind.transfer,
          fetch: fetch,
          toJson: (id) => {'id': id},
          fromJson: (json) => json['id'] as String,
        ),
      ),
    );

    test(
      'en ligne : la liste est rendue ET gardée pour la prochaine coupure',
      () async {
        final c = container();
        expect((await run(c, () async => ['o1', 'o2'])).items, ['o1', 'o2']);

        final kept = await cache.read('m', DocumentKind.transfer);
        expect(kept.documents.map((d) => d['id']), ['o1', 'o2']);
      },
    );

    test('hors ligne : la dernière liste connue s’ouvre quand même', () async {
      final c = container();
      await run(c, () async => ['o1']);

      final offline = await run(
        c,
        () async =>
            throw const ApiException(statusCode: 0, message: 'hors ligne'),
      );
      expect(offline.items, ['o1']);
      expect(offline.cachedAt, isNotNull, reason: 'la copie est DATÉE');
    });

    test(
      'hors ligne SANS copie : l’écran reste en erreur, pas une liste vide',
      () async {
        final c = container();
        Object? thrown;
        try {
          await run(
            c,
            () async =>
                throw const ApiException(statusCode: 0, message: 'hors ligne'),
          );
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ApiException>());
      },
    );

    test(
      'refus métier : remonté tel quel, la copie locale ne le masque pas',
      () async {
        final c = container();
        await run(c, () async => ['o1']);

        Object? thrown;
        try {
          await run(
            c,
            () async => throw const ApiException(
              statusCode: 403,
              message: 'Permission manquante',
              code: 'FORBIDDEN_PERMISSION',
            ),
          );
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ApiException>());
        expect((thrown! as ApiException).statusCode, 403);
      },
    );
  });
}
