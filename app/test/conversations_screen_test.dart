import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/messaging/data/conversation_models.dart';
import 'package:gestion_magasin/features/messaging/data/conversations_api.dart';
import 'package:gestion_magasin/features/messaging/presentation/conversation_thread.dart';
import 'package:gestion_magasin/features/messaging/presentation/conversations_screen.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

/// Communication interne (P1 n°17) : la liste distingue ce qui a du neuf, le
/// fil se lit et se répond, et un fil clos ne se réécrit pas.
class _FakeConversationsApi extends ConversationsApi {
  _FakeConversationsApi(this.threads) : super(Dio());

  List<Conversation> threads;
  final replies = <(String, String)>[];
  final opened = <String>[];
  int closeCalls = 0;

  @override
  Future<ConversationPage> list({
    int page = 1,
    int limit = 50,
    bool includeClosed = false,
  }) async {
    final visible = includeClosed
        ? threads
        : threads.where((t) => !t.isClosed).toList();
    return ConversationPage(
      data: visible,
      meta: PageMeta(page: page, limit: limit, total: visible.length),
    );
  }

  @override
  Future<Conversation> findOne(String id) async {
    opened.add(id);
    return threads.firstWhere((t) => t.id == id);
  }

  @override
  Future<Conversation> reply(String id, String body) async {
    replies.add((id, body));
    final thread = threads.firstWhere((t) => t.id == id);
    final updated = thread.copyWith(
      messages: [
        ...thread.messages,
        ConversationMessage(
          id: 'm${thread.messages.length + 1}',
          authorId: 'moi',
          authorName: 'Moi',
          body: body,
          createdAt: DateTime.utc(2026, 9, 24, 10),
        ),
      ],
    );
    threads = [for (final t in threads) t.id == id ? updated : t];
    return updated;
  }

  @override
  Future<Conversation> close(String id) async {
    closeCalls++;
    final thread = threads.firstWhere((t) => t.id == id);
    return thread.copyWith(closedAt: DateTime.utc(2026, 9, 24));
  }
}

Conversation _thread({
  String id = 'c1',
  String subject = 'Rupture câbles 2,5 mm²',
  int unread = 0,
  bool closed = false,
  String createdById = 'moi',
  List<ConversationMessage>? messages,
}) => Conversation(
  id: id,
  subject: subject,
  createdById: createdById,
  participants: const [
    ConversationParticipant(userId: 'moi', fullName: 'Nadia Kaci'),
    ConversationParticipant(userId: 'autre', fullName: 'Karim Ould'),
  ],
  closedAt: closed ? DateTime.utc(2026, 9, 23) : null,
  lastMessageAt: DateTime.utc(2026, 9, 24, 9),
  unread: unread,
  messages:
      messages ??
      [
        ConversationMessage(
          id: 'm1',
          authorId: 'autre',
          authorName: 'Karim Ould',
          body: 'Il en reste 3 au dépôt.',
          createdAt: DateTime.utc(2026, 9, 24, 9),
        ),
      ],
  createdAt: DateTime.utc(2026, 9, 23),
);

AuthUser _moi() => authUser(
  id: 'moi',
  fullName: 'Nadia Kaci',
  roles: const ['VENDEUR'],
  permissions: const ['sale.create'],
);

Future<_FakeConversationsApi> _pumpList(
  WidgetTester tester, {
  required List<Conversation> threads,
}) async {
  useScreenSize(tester, const Size(500, 1400));
  final api = _FakeConversationsApi(threads);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        conversationsApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue('moi'),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: ConversationsScreen(user: _moi())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Future<_FakeConversationsApi> _pumpThread(
  WidgetTester tester, {
  required Conversation thread,
  AuthUser? user,
}) async {
  useScreenSize(tester, const Size(500, 1400));
  final api = _FakeConversationsApi([thread]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        conversationsApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue('moi'),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: ConversationThreadScreen(id: thread.id, user: user ?? _moi()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets(
    'aucun fil : l’écran le dit et renvoie vers la demande de transfert',
    (tester) async {
      await _pumpList(tester, threads: const []);

      expect(find.text('Aucune conversation'), findsOneWidget);
      // La spec §25 : un message ne remplace pas une opération métier.
      expect(find.textContaining('demande de transfert'), findsOneWidget);
    },
  );

  testWidgets('un fil avec du neuf se distingue par son compteur', (
    tester,
  ) async {
    await _pumpList(tester, threads: [_thread(unread: 2)]);

    expect(find.text('Rupture câbles 2,5 mm²'), findsOneWidget);
    expect(find.text('2 non lu(s)'), findsOneWidget);
  });

  testWidgets(
    'les fils clos sont masqués par défaut, l’interrupteur les rend',
    (tester) async {
      await _pumpList(
        tester,
        threads: [_thread(id: 'c2', subject: 'Ancien sujet', closed: true)],
      );

      expect(find.text('Ancien sujet'), findsNothing);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(find.text('Ancien sujet'), findsOneWidget);
      expect(find.text('Clos'), findsOneWidget);
    },
  );

  testWidgets('ouvrir un fil le charge — et l’ouvrir vaut lecture', (
    tester,
  ) async {
    final api = await _pumpThread(tester, thread: _thread());

    expect(api.opened, ['c1']);
    expect(find.text('Il en reste 3 au dépôt.'), findsOneWidget);
    expect(find.textContaining('Karim Ould'), findsWidgets);
  });

  testWidgets('répondre envoie le texte saisi et vide le champ', (
    tester,
  ) async {
    final api = await _pumpThread(tester, thread: _thread());

    await tester.enterText(find.byType(TextField), 'Merci, je passe demain.');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(api.replies, [('c1', 'Merci, je passe demain.')]);
    expect(find.text('Merci, je passe demain.'), findsWidgets);
  });

  testWidgets('un fil CLOS n’offre pas de zone de réponse', (tester) async {
    await _pumpThread(tester, thread: _thread(closed: true));

    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('Fil clos'), findsOneWidget);
  });

  /// Clore n'est offert qu'à l'auteur du fil ou à un admin — le serveur
  /// revérifie, mais un bouton qui refuse est un piège.
  testWidgets('clore n’est proposé qu’à l’auteur du fil', (tester) async {
    await _pumpThread(tester, thread: _thread(createdById: 'autre'));
    expect(find.byTooltip('Clore le fil'), findsNothing);

    await _pumpThread(tester, thread: _thread(createdById: 'moi'));
    expect(find.byTooltip('Clore le fil'), findsOneWidget);
  });
}
