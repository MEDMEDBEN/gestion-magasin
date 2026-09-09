import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/api/auth_api.dart';
import '../data/api/dio_client.dart';
import '../data/api/sync_api.dart';
import '../data/local/app_database.dart';
import '../data/local/mutation_queue.dart';
import '../data/local/token_store.dart';
import '../data/sync/sync_engine.dart';
import '../features/auth/application/auth_controller.dart';

/// Câblage des dépendances. Tout est surchargeable en test via `overrideWith`.

final uuidProvider = Provider<Uuid>((ref) => const Uuid());

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final mutationQueueProvider = Provider<MutationQueue>(
  (ref) => MutationQueue(
    ref.watch(appDatabaseProvider),
    uuid: ref.watch(uuidProvider),
  ),
);

final dioClientProvider = Provider<DioClient>((ref) {
  return DioClient(
    tokenStore: ref.watch(tokenStoreProvider),
    // Le refresh a définitivement échoué : on ramène l'app à l'écran de login.
    onSessionExpired: () async =>
        ref.read(authControllerProvider.notifier).onSessionExpired(),
  );
});

final authApiProvider =
    Provider<AuthApi>((ref) => AuthApi(ref.watch(dioClientProvider).dio));

final syncApiProvider =
    Provider<SyncApi>((ref) => SyncApi(ref.watch(dioClientProvider).dio));

final syncEngineProvider = Provider<SyncEngine>(
  (ref) => SyncEngine(
    api: ref.watch(syncApiProvider),
    queue: ref.watch(mutationQueueProvider),
  ),
);

/// Identifiant stable de l'appareil, créé une fois puis conservé.
final deviceIdProvider = FutureProvider<String>((ref) {
  final uuid = ref.watch(uuidProvider);
  return ref.watch(tokenStoreProvider).deviceId(uuid.v4);
});

/// Nombre de mutations en attente — alimente l'indicateur PERMANENT.
/// Flux (et non Future) : il doit refléter la file en direct après une saisie
/// hors-ligne ou un cycle de sync, sans qu'on pense à l'invalider.
final pendingMutationsCountProvider = StreamProvider<int>(
  (ref) => ref.watch(mutationQueueProvider).watchPendingCount(),
);

/// Mutations REJETÉES par le serveur : elles exigent une action de
/// l'utilisateur (annuler, ou corriger via une nouvelle mutation) —
/// docs/context.md §6. Sans cette liste, une vente refusée disparaîtrait
/// silencieusement de l'écran.
final rejectedMutationsProvider = StreamProvider<List<PendingMutation>>(
  (ref) => ref.watch(mutationQueueProvider).watchRejected(),
);
