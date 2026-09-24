import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../application/conversations_controller.dart';
import '../data/conversation_models.dart';
import '../data/conversations_api.dart';
import 'conversation_form.dart';
import 'conversation_thread.dart';

/// Communication interne (spec §25) : mes fils, le plus récemment animé en tête.
///
/// Écran délibérément pauvre : pas de pièce jointe, pas de recherche, pas
/// d'édition. « Une opération métier structurée ne doit jamais être remplacée
/// par un message » — un rappel est affiché à la création d'un fil.
class ConversationsScreen extends ConsumerStatefulWidget {
  const ConversationsScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<ConversationsScreen> createState() =>
      _ConversationsScreenState();
}

class _ConversationsScreenState extends ConsumerState<ConversationsScreen> {
  bool _includeClosed = false;

  @override
  Widget build(BuildContext context) {
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final threads = ref.watch(conversationsProvider(_includeClosed));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Switch(
                      value: _includeClosed,
                      onChanged: (value) =>
                          setState(() => _includeClosed = value),
                    ),
                    const SizedBox(width: 6),
                    const Text('Afficher les fils clos'),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: () => openConversationForm(context, widget.user),
                icon: const Icon(LucideIcons.plus, size: 17),
                label: const Text('Nouveau fil'),
              ),
            ],
          ),
        ),
        Expanded(
          child: threads.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException
                  ? error.userMessage
                  : 'Vos conversations n’ont pas pu être chargées.',
              onRetry: () =>
                  ref.invalidate(conversationsProvider(_includeClosed)),
            ),
            data: (page) => page.data.isEmpty
                ? ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Aucune conversation',
                    message:
                        'Pour une question ou une consigne entre le magasin et '
                        'le dépôt. Pour demander de la marchandise, passez par '
                        'une demande de transfert.',
                    action: FilledButton.icon(
                      onPressed: () =>
                          openConversationForm(context, widget.user),
                      icon: const Icon(LucideIcons.plus, size: 17),
                      label: const Text('Nouveau fil'),
                    ),
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final thread in page.data)
                        _ThreadTile(thread: thread, user: widget.user),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _ThreadTile extends ConsumerWidget {
  const _ThreadTile({required this.thread, required this.user});

  final Conversation thread;
  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final others = thread.participants
        .where((p) => p.userId != user.id)
        .map((p) => p.fullName)
        .join(', ');

    return Card(
      // Un fil qui a du neuf se distingue sans avoir à lire la date.
      color: thread.unread > 0 ? colors.surface2 : null,
      child: ListTile(
        minTileHeight: AmpereGeometry.listRowMin,
        title: Text(thread.subject, style: AmpereType.rowTitle),
        subtitle: Text(
          '${others.isEmpty ? 'Fil personnel' : others} · '
          '${formatDateTime(thread.lastMessageAt)}',
        ),
        trailing: thread.isClosed
            ? const AmpereBadge(label: 'Clos', tone: StatusTone.neutral)
            : thread.unread > 0
            ? AmpereBadge(
                label: '${thread.unread} non lu(s)',
                tone: StatusTone.info,
              )
            : null,
        onTap: () async {
          await openConversationThread(context, thread.id, user);
          // De retour du fil : les non-lus ont bougé, la liste doit suivre.
          ref.invalidate(conversationsProvider(true));
          ref.invalidate(conversationsProvider(false));
        },
      ),
    );
  }
}

/// Exposé pour l'écran du fil : répondre puis recharger.
Future<void> replyTo(WidgetRef ref, String id, String body) async {
  await ref.read(conversationsApiProvider).reply(id, body);
  ref.invalidate(conversationProvider(id));
}
