import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../data/models/page_meta.dart';

part 'conversation_models.freezed.dart';
part 'conversation_models.g.dart';

@freezed
abstract class ConversationParticipant with _$ConversationParticipant {
  const factory ConversationParticipant({
    required String userId,
    required String fullName,
  }) = _ConversationParticipant;

  factory ConversationParticipant.fromJson(Map<String, dynamic> json) =>
      _$ConversationParticipantFromJson(json);
}

/// Membre à qui on peut écrire. Identifiant et nom SEULEMENT : ni email, ni
/// rôle, ni état du compte — la fiche d'un collègue ne regarde que l'admin.
@freezed
abstract class ConversationRecipient with _$ConversationRecipient {
  const factory ConversationRecipient({
    required String id,
    required String fullName,
  }) = _ConversationRecipient;

  factory ConversationRecipient.fromJson(Map<String, dynamic> json) =>
      _$ConversationRecipientFromJson(json);
}

@freezed
abstract class ConversationMessage with _$ConversationMessage {
  const factory ConversationMessage({
    required String id,
    required String authorId,
    required String authorName,
    required String body,
    required DateTime createdAt,
  }) = _ConversationMessage;

  factory ConversationMessage.fromJson(Map<String, dynamic> json) =>
      _$ConversationMessageFromJson(json);
}

/// Un fil. `messages` n'est rempli que sur le DÉTAIL : la liste ne les
/// descend pas, elle n'en a pas besoin.
@freezed
abstract class Conversation with _$Conversation {
  const factory Conversation({
    required String id,
    required String subject,
    required String createdById,
    @Default(<ConversationParticipant>[])
    List<ConversationParticipant> participants,
    DateTime? closedAt,
    required DateTime lastMessageAt,
    @Default(0) int unread,
    @Default(<ConversationMessage>[]) List<ConversationMessage> messages,
    required DateTime createdAt,
  }) = _Conversation;

  const Conversation._();

  bool get isClosed => closedAt != null;

  factory Conversation.fromJson(Map<String, dynamic> json) =>
      _$ConversationFromJson(json);
}

@freezed
abstract class ConversationPage with _$ConversationPage {
  const factory ConversationPage({
    required List<Conversation> data,
    required PageMeta meta,
  }) = _ConversationPage;

  factory ConversationPage.fromJson(Map<String, dynamic> json) =>
      _$ConversationPageFromJson(json);
}
