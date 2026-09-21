import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/config/app_config.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/offline_write.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/data/sync/sync_coordinator.dart';
import 'package:gestion_magasin/data/sync/sync_engine.dart';

class _FakeEngine implements SyncEngine {
  final calls = <String>[];
  Object? failWith;

  @override
  Future<SyncOutcome> synchronizeAll({
    required String authorUserId,
    int maxBatches = 10,
  }) async {
    calls.add(authorUserId);
    if (failWith != null) throw failWith!;
    return const SyncOutcome(
      sent: 1,
      confirmed: 1,
      rejected: 0,
      stillPending: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Compte connecté pilotable (connexion / déconnexion) sans monter l'auth.
class _User extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? id) => state = id;
}

final _user = NotifierProvider<_User, String?>(_User.new);

/// `writeOnlineOrQueue` a besoin d'un `Ref` : on passe par un provider de test.
final _writer = Provider(
  (ref) =>
      (Future<String> Function(Map<String, dynamic> body) online) =>
          writeOnlineOrQueue<String>(
            ref,
            intent: 'sale:panier',
            operationType: 'SALE',
            payload: (key) => {'id': key, 'total': 1200},
            online: online,
          ),
);

void main() {
  late _FakeEngine engine;
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    engine = _FakeEngine();
    db = AppDatabase.forTesting();
    container = ProviderContainer(
      overrides: [
        syncEngineProvider.overrideWithValue(engine),
        currentUserIdProvider.overrideWith((ref) => ref.watch(_user)),
        appDatabaseProvider.overrideWithValue(db),
        deviceIdProvider.overrideWith((ref) async => 'appareil-1'),
      ],
    );
    container.listen(syncCoordinatorProvider, (_, _) {});
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('SyncCoordinator', () {
    test('aucun compte : rien ne part', () async {
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, isEmpty);
    });

    test('connexion : la file du compte part tout de suite', () async {
      container.read(_user.notifier).set('u1');
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, ['u1']);
      expect(container.read(syncCoordinatorProvider)?.confirmed, 1);
    });

    test('retour du réseau : on n’attend pas le battement', () async {
      container.read(_user.notifier).set('u1');
      await Future<void>.delayed(Duration.zero);
      container.read(serverReachableProvider.notifier).report(false);
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, ['u1'], reason: 'la coupure ne déclenche rien');
      container.read(serverReachableProvider.notifier).report(true);
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, ['u1', 'u1']);
    });

    test('changement de compte : c’est la file du NOUVEAU qui part', () async {
      container.read(_user.notifier).set('u1');
      await Future<void>.delayed(Duration.zero);
      container.read(_user.notifier).set('u2');
      container.read(syncCoordinatorProvider);
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, ['u1', 'u2']);
    });

    test('battement : la file repart périodiquement, et s’arrête à la '
        'déconnexion', () {
      fakeAsync((async) {
        container.read(_user.notifier).set('u1');
        container.read(syncCoordinatorProvider);
        async.flushMicrotasks();
        expect(engine.calls, hasLength(1));
        async.elapse(AppConfig.syncInterval * 2);
        expect(engine.calls, hasLength(3));

        container.read(_user.notifier).set(null);
        container.read(syncCoordinatorProvider);
        async.elapse(AppConfig.syncInterval * 3);
        expect(engine.calls, hasLength(3));
      });
    });

    test('un échec ne remonte jamais : la boucle de fond survit', () async {
      engine.failWith = StateError('base fermée');
      container.read(_user.notifier).set('u1');
      await Future<void>.delayed(Duration.zero);
      expect(
        await container.read(syncCoordinatorProvider.notifier).kick(),
        isNull,
      );
    });
  });

  group('writeOnlineOrQueue', () {
    setUp(() => container.read(_user.notifier).set('u1'));

    Future<List<PendingMutation>> queued() =>
        db.select(db.pendingMutations).get();

    test('en ligne : appliqué, rien en file', () async {
      final outcome = await container.read(_writer)((body) async => 'vente');
      expect(outcome, isA<Applied<String>>());
      expect(await queued(), isEmpty);
    });

    test('hors ligne : mis en file avec la MÊME clé et le MÊME corps que '
        'l’essai en ligne', () async {
      Map<String, dynamic>? sent;
      final outcome = await container.read(_writer)((body) async {
        sent = body;
        throw const ApiException(statusCode: 0, message: 'hors ligne');
      });
      expect(outcome, isA<Queued<String>>());
      final rows = await queued();
      expect(rows, hasLength(1));
      expect(
        rows.single.clientMutationId,
        (outcome as Queued).clientMutationId,
      );
      expect(rows.single.clientMutationId, sent!['id']);
      expect(jsonDecode(rows.single.payload), sent);
      expect(rows.single.authorUserId, 'u1');
      expect(rows.single.operationType, 'SALE');
    });

    test(
      'après mise en file, l’opération suivante a une NOUVELLE clé',
      () async {
        final ids = <Object?>[];
        for (var i = 0; i < 2; i++) {
          await container.read(_writer)((body) async {
            ids.add(body['id']);
            throw const ApiException(statusCode: 0, message: 'hors ligne');
          });
        }
        expect(ids[0], isNot(ids[1]));
        expect(await queued(), hasLength(2));
      },
    );

    test(
      'compte changé PENDANT l’essai en ligne : rien en file (sécu E1)',
      () async {
        await expectLater(
          container.read(_writer)((body) async {
            container.read(_user.notifier).set('u2');
            throw const ApiException(statusCode: 0, message: 'hors ligne');
          }),
          throwsA(isA<ApiException>()),
        );
        expect(await queued(), isEmpty);
      },
    );

    test('refus métier : l’erreur remonte, RIEN en file', () async {
      await expectLater(
        container.read(_writer)(
          (body) async => throw const ApiException(
            statusCode: 422,
            message: 'Stock insuffisant',
            code: 'STOCK_INSUFFICIENT',
          ),
        ),
        throwsA(isA<ApiException>()),
      );
      expect(await queued(), isEmpty);
    });
  });
}
