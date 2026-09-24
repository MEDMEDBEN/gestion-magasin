import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'conversation_models.dart';

/// Fils de discussion du compte connecté. Le serveur ne rend que ceux dont je
/// suis participant : aucun identifiant de destinataire ne part d'ici.
class ConversationsApi {
  ConversationsApi(this._dio);

  final Dio _dio;

  Future<ConversationPage> list({
    int page = 1,
    int limit = 50,
    bool includeClosed = false,
  }) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/conversations',
        queryParameters: {
          'page': page,
          'limit': limit,
          if (includeClosed) 'includeClosed': 'true',
        },
      );
      return ConversationPage.fromJson(response.data!);
    });
  }

  /// Ouvre le fil ET le marque lu côté serveur : c'est l'acte de l'ouvrir qui
  /// vaut lecture, pas un bouton à presser.
  Future<Conversation> findOne(String id) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/conversations/$id',
      );
      return Conversation.fromJson(response.data!);
    });
  }

  /// À qui je peux écrire : identifiant et nom, rien d'autre. Route dédiée —
  /// la liste des comptes (`/users`) est réservée à l'admin, et c'est pourtant
  /// le magasinier qui a le plus besoin de poser une question.
  Future<List<ConversationRecipient>> recipients() {
    return guardApi(() async {
      final response = await _dio.get<List<dynamic>>(
        '/conversations/recipients',
      );
      return [
        for (final row in response.data ?? const [])
          ConversationRecipient.fromJson(row as Map<String, dynamic>),
      ];
    });
  }

  Future<Conversation> create({
    required String subject,
    required List<String> participantIds,
    required String body,
  }) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/conversations',
        data: {
          'subject': subject,
          'participantIds': participantIds,
          'body': body,
        },
      );
      return Conversation.fromJson(response.data!);
    });
  }

  Future<Conversation> reply(String id, String body) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/conversations/$id/messages',
        data: {'body': body},
      );
      return Conversation.fromJson(response.data!);
    });
  }

  Future<Conversation> close(String id) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/conversations/$id/close',
      );
      return Conversation.fromJson(response.data!);
    });
  }
}

final conversationsApiProvider = Provider<ConversationsApi>(
  (ref) => ConversationsApi(ref.watch(dioClientProvider).dio),
);
