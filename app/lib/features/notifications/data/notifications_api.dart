import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'notification_models.dart';

/// Boîte de réception du compte connecté. Le serveur ne rend que SES
/// notifications : aucun identifiant de destinataire ne part d'ici.
class NotificationsApi {
  NotificationsApi(this._dio);

  final Dio _dio;

  Future<NotificationPage> list({
    int page = 1,
    int limit = 30,
    bool unreadOnly = false,
  }) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/notifications',
        queryParameters: {
          'page': page,
          'limit': limit,
          if (unreadOnly) 'unreadOnly': true,
        },
      );
      return NotificationPage.fromJson(response.data!);
    });
  }

  /// Rend le nombre de non lues RESTANTES : le badge vient du serveur, il n'est
  /// pas recalculé de mémoire côté app.
  Future<int> markRead(String id) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/notifications/$id/read',
      );
      return response.data!['unread'] as int;
    });
  }

  Future<int> markAllRead() {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/notifications/read-all',
      );
      return response.data!['unread'] as int;
    });
  }
}

final notificationsApiProvider = Provider<NotificationsApi>(
  (ref) => NotificationsApi(ref.watch(dioClientProvider).dio),
);
