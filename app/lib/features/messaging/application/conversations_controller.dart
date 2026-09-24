import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/models/page_meta.dart';
import '../../../data/sync/sync_coordinator.dart';
import '../data/conversation_models.dart';
import '../data/conversations_api.dart';

/// Mes fils, lus EN LIGNE et rafraîchis au battement de synchro — c'est lui qui
/// fait ARRIVER les réponses pendant qu'on travaille. Rien n'est gardé sur
/// l'appareil : un fil périmé ferait croire à une conversation close ou à un
/// message jamais envoyé.
final conversationsProvider = FutureProvider.autoDispose
    .family<ConversationPage, bool>((ref, includeClosed) async {
      final userId = ref.watch(currentUserIdProvider);
      if (userId == null) {
        return const ConversationPage(
          data: [],
          meta: PageMeta(page: 1, limit: 0, total: 0),
        );
      }
      ref.watch(serverReachableProvider);
      ref.watch(syncCoordinatorProvider);
      return ref
          .watch(conversationsApiProvider)
          .list(includeClosed: includeClosed);
    });

/// Un fil et ses messages. Le LIRE le marque lu côté serveur : ne le charge que
/// lorsque l'utilisateur l'ouvre vraiment.
final conversationProvider = FutureProvider.autoDispose
    .family<Conversation, String>((ref, id) async {
      ref.watch(currentUserIdProvider);
      ref.watch(syncCoordinatorProvider);
      return ref.watch(conversationsApiProvider).findOne(id);
    });

/// Membres à qui écrire. Route DÉDIÉE (id + nom) : la liste des comptes est
/// réservée à l'admin, or les trois rôles doivent pouvoir ouvrir un fil.
final conversationRecipientsProvider =
    FutureProvider.autoDispose<List<ConversationRecipient>>((ref) async {
      ref.watch(currentUserIdProvider);
      return ref.watch(conversationsApiProvider).recipients();
    });
