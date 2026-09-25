import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/models/page_meta.dart';
import '../../../data/sync/sync_coordinator.dart';
import '../data/problem_models.dart';
import '../data/problems_api.dart';

/// Filtre de l'écran : ce qu'on regarde, et seulement les miens ou tous.
typedef ProblemFilter = ({ProblemStatus? status, bool mine});

/// Les signalements de l'équipe, lus EN LIGNE et rafraîchis au battement de
/// synchro. Rien n'est gardé sur l'appareil : un signalement déjà résolu qu'on
/// croirait ouvert enverrait quelqu'un travailler pour rien.
final problemsProvider = FutureProvider.autoDispose
    .family<ProblemPage, ProblemFilter>((ref, filter) async {
      final userId = ref.watch(currentUserIdProvider);
      if (userId == null) {
        return const ProblemPage(
          data: [],
          meta: PageMeta(page: 1, limit: 0, total: 0),
        );
      }
      ref.watch(serverReachableProvider);
      ref.watch(syncCoordinatorProvider);
      return ref
          .watch(problemsApiProvider)
          .list(status: filter.status, mine: filter.mine);
    });

/// Photo d'un signalement, chargée À LA DEMANDE, à l'ouverture de la fiche.
///
/// PAS de `keepAlive` : sur un poste partagé, rien de la session précédente ne
/// doit rester en mémoire (CONVENTIONS.md). Recharger une image à la réouverture
/// d'une fiche est un aller-retour, pas un problème.
final problemPhotoProvider = FutureProvider.autoDispose
    .family<Uint8List, String>(
      (ref, problemId) => ref.watch(problemsApiProvider).photoBytes(problemId),
    );
