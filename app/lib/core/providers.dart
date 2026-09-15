import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/api/dio_client.dart';
import '../data/api/sync_api.dart';
import '../data/local/app_database.dart';
import '../data/local/local_settings_store.dart';
import '../data/local/mutation_queue.dart';
import '../data/local/token_store.dart';
import '../data/sync/sync_engine.dart';
import '../features/auth/application/auth_controller.dart';

/// Câblage des dépendances d'INFRASTRUCTURE partagées par toutes les features.
/// Les clients d'API propres à une feature vivent dans `features/<f>/data/`.
/// Tout est surchargeable en test via `overrideWith`.

final uuidProvider = Provider<Uuid>((ref) => const Uuid());

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final localSettingsStoreProvider = Provider<LocalSettingsStore>(
  (ref) => LocalSettingsStore(ref.watch(appDatabaseProvider)),
);

final mutationQueueProvider = Provider<MutationQueue>(
  (ref) => MutationQueue(
    ref.watch(appDatabaseProvider),
    uuid: ref.watch(uuidProvider),
  ),
);

/// Le serveur a-t-il répondu au dernier échange ? Alimente l'état « Hors ligne »
/// de l'indicateur de synchronisation (AMPÈRE §7) — vrai tant qu'on n'a pas la
/// preuve du contraire.
class ServerReachability extends Notifier<bool> {
  @override
  bool build() => true;

  void report(bool reachable) {
    if (state != reachable) state = reachable;
  }
}

final serverReachableProvider = NotifierProvider<ServerReachability, bool>(
  ServerReachability.new,
);

final dioClientProvider = Provider<DioClient>((ref) {
  return DioClient(
    tokenStore: ref.watch(tokenStoreProvider),
    // Le refresh a définitivement échoué : on ramène l'app à l'écran de login.
    onSessionExpired: () async =>
        ref.read(authControllerProvider.notifier).onSessionExpired(),
    onReachability: (reachable) =>
        ref.read(serverReachableProvider.notifier).report(reachable),
  );
});

final syncApiProvider = Provider<SyncApi>(
  (ref) => SyncApi(ref.watch(dioClientProvider).dio),
);

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

/// Compte connecté, ou `null`. Les données propres à un compte (file de
/// mutations, préférences, listes chargées) se recalculent quand il change :
/// rien de l'utilisateur précédent ne reste à l'écran d'un poste partagé.
final currentUserIdProvider = Provider<String?>((ref) {
  return switch (ref.watch(authControllerProvider).value) {
    AuthSignedIn(:final user) => user.id,
    _ => null,
  };
});

/// Nombre de mutations en attente DU COMPTE CONNECTÉ — alimente l'indicateur
/// PERMANENT. Flux (et non Future) : il doit refléter la file en direct après
/// une saisie hors-ligne ou un cycle de sync, sans qu'on pense à l'invalider.
final pendingMutationsCountProvider = StreamProvider<int>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(0);
  return ref
      .watch(mutationQueueProvider)
      .watchPendingCount(authorUserId: userId);
});

/// Mutations en attente laissées sur cet appareil par un AUTRE compte :
/// elles ne partiront pas avec cette session (audit I2), on le signale.
final foreignPendingMutationsCountProvider = StreamProvider<int>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(0);
  return ref
      .watch(mutationQueueProvider)
      .watchForeignPendingCount(authorUserId: userId);
});

/// Mutations REJETÉES par le serveur : elles exigent une action de
/// l'utilisateur (annuler, ou corriger via une nouvelle mutation) —
/// docs/context.md §6. Sans cette liste, une vente refusée disparaîtrait
/// silencieusement de l'écran.
final rejectedMutationsProvider = StreamProvider<List<PendingMutation>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const []);
  return ref.watch(mutationQueueProvider).watchRejected(authorUserId: userId);
});
