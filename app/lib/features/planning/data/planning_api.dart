import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'planning_models.dart';

/// Vue de l'écran : les tâches ouvertes (le travail à faire), celles en
/// retard, ou celles closes. Jamais « tout », qui grossirait sans fin : les
/// tâches terminées s'accumulent semaine après semaine.
enum PlanningView {
  open('À faire'),
  late('En retard'),
  done('Terminées');

  const PlanningView(this.label);
  final String label;
}

/// Accès réseau du planning. Aucune règle ici : le serveur cloisonne les
/// tâches par membre, calcule le retard et tient la machine à états.
class PlanningApi {
  PlanningApi(this._dio);

  final Dio _dio;

  /// `assignedToId` n'est honoré par le serveur que pour l'admin.
  Future<PlanningTaskPage> list({
    String? assignedToId,
    PlanningView view = PlanningView.open,
    int limit = 200,
  }) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/planning-tasks',
        queryParameters: {
          'limit': limit,
          'assignedToId': ?assignedToId,
          ...switch (view) {
            // Le plus urgent d'abord.
            PlanningView.open => {'open': 'true', 'sort': 'dueDate:asc'},
            PlanningView.late => {'late': 'true', 'sort': 'dueDate:asc'},
            // Le plus récent d'abord : une troncature coupe l'ANCIEN.
            PlanningView.done => {
              'status': 'TERMINEE',
              'sort': 'completedAt:desc',
            },
          },
        },
      );
      return PlanningTaskPage.fromJson(response.data!);
    });
  }

  Future<PlanningTask> create(Map<String, Object?> fields) =>
      _send('POST', '/planning-tasks', fields);

  /// N'envoyer QUE les champs modifiés : une échéance déjà passée, renvoyée
  /// telle quelle, serait refusée par le serveur.
  Future<PlanningTask> update(String id, Map<String, Object?> changes) =>
      _send('PATCH', '/planning-tasks/$id', changes);

  Future<PlanningTask> start(String id) =>
      _send('POST', '/planning-tasks/$id/start', null);

  Future<PlanningTask> complete(String id, String result, String? comment) =>
      _send('POST', '/planning-tasks/$id/complete', {
        'result': result,
        'comment': ?comment,
      });

  Future<void> remove(String id) {
    return guardApi(() async {
      await _dio.delete<void>('/planning-tasks/$id');
    });
  }

  Future<PlanningTask> _send(
    String method,
    String path,
    Map<String, Object?>? fields,
  ) {
    return guardApi(() async {
      final response = await _dio.request<Map<String, dynamic>>(
        path,
        data: fields,
        options: Options(method: method),
      );
      return PlanningTask.fromJson(response.data!);
    });
  }
}

final planningApiProvider = Provider<PlanningApi>(
  (ref) => PlanningApi(ref.watch(dioClientProvider).dio),
);
