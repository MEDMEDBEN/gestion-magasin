import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/providers.dart';
import 'sync_engine.dart';

/// Chef d'orchestre de la synchronisation : QUAND pousser la file.
///
/// Le moteur (`SyncEngine`) sait COMMENT ; celui-ci décide du moment — à la
/// connexion d'un compte, au retour du réseau, puis à intervalle régulier
/// (`AppConfig.syncInterval`). Sans lui, une vente mise en file hors-ligne y
/// resterait jusqu'à ce que quelqu'un y pense : c'était l'état de l'app avant la
/// P0 #12 (le moteur existait, rien ne le déclenchait).
///
/// L'état exposé est le dernier résultat, pour l'écran de synchronisation.
class SyncCoordinator extends Notifier<SyncOutcome?> {
  Timer? _heartbeat;

  @override
  SyncOutcome? build() {
    final userId = ref.watch(currentUserIdProvider);
    ref.onDispose(() => _heartbeat?.cancel());
    if (userId == null) return null;

    // Retour du réseau : on n'attend pas le prochain battement.
    ref.listen(serverReachableProvider, (was, now) {
      if (was == false && now) unawaited(kick());
    });
    _heartbeat = Timer.periodic(AppConfig.syncInterval, (_) => kick());
    // Connexion (ou changement de compte) : ce qui attendait part tout de suite.
    Future.microtask(kick);
    return null;
  }

  /// Pousse la file du compte connecté. Jamais d'exception vers l'appelant :
  /// c'est une boucle de fond — un échec (réseau, base locale fermée pendant une
  /// déconnexion) se réessaie au battement suivant.
  Future<SyncOutcome?> kick() async {
    if (!ref.mounted) return null;
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return null;
    try {
      final outcome = await ref
          .read(syncEngineProvider)
          .synchronizeAll(authorUserId: userId);
      // Le cycle d'un compte déconnecté entre-temps ne s'affiche pas au suivant.
      if (ref.mounted && ref.read(currentUserIdProvider) == userId) {
        state = outcome;
      }
      return outcome;
    } catch (error, stack) {
      debugPrint('Synchronisation interrompue : $error\n$stack');
      return null;
    }
  }
}

final syncCoordinatorProvider = NotifierProvider<SyncCoordinator, SyncOutcome?>(
  SyncCoordinator.new,
);
