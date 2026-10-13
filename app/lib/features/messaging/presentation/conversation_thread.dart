import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../application/conversations_controller.dart';
import '../data/conversation_models.dart';
import '../data/conversations_api.dart';
import 'conversations_screen.dart' show PersonAvatar, avatarColor;

/// Ouvre un fil en plein écran. L'ouvrir vaut LECTURE côté serveur.
Future<void> openConversationThread(
  BuildContext context,
  String id,
  AuthUser user,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => ConversationThreadScreen(id: id, user: user),
  ),
);

class ConversationThreadScreen extends ConsumerStatefulWidget {
  const ConversationThreadScreen({
    super.key,
    required this.id,
    required this.user,
  });

  final String id;
  final AuthUser user;

  @override
  ConsumerState<ConversationThreadScreen> createState() =>
      _ConversationThreadScreenState();
}

class _ConversationThreadScreenState
    extends ConsumerState<ConversationThreadScreen> {
  final _reply = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thread = ref.watch(conversationProvider(widget.id));

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(thread.value?.subject ?? 'Conversation'),
            if (thread.value case final value?)
              Text(
                value.participants.map((p) => p.fullName).join(', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AmpereType.meta.copyWith(
                  color: AmpereColors.of(context).ink3,
                ),
              ),
          ],
        ),
        actions: [
          // Clore : l'auteur du fil ou un admin. Le serveur revérifie.
          if (thread.value case final value?)
            if (!value.isClosed &&
                (value.createdById == widget.user.id ||
                    widget.user.hasRole('ADMIN')))
              IconButton(
                tooltip: 'Clore le fil',
                onPressed: _close,
                icon: const Icon(LucideIcons.archive, size: 19),
              ),
        ],
      ),
      body: thread.when(
        loading: () => const AmpereSkeletonList(rows: 4),
        error: (error, _) => ScreenStateView(
          status: error is ApiException && error.isOffline
              ? ScreenStatus.offline
              : ScreenStatus.error,
          message: error is ApiException
              ? error.userMessage
              : 'Ce fil n’a pas pu être chargé.',
          onRetry: () => ref.invalidate(conversationProvider(widget.id)),
        ),
        data: (value) => Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                children: [
                  for (var i = 0; i < value.messages.length; i++) ...[
                    // Séparateur de jour, comme une vraie messagerie.
                    if (i == 0 ||
                        DateUtils.dateOnly(
                              value.messages[i].createdAt.toLocal(),
                            ) !=
                            DateUtils.dateOnly(
                              value.messages[i - 1].createdAt.toLocal(),
                            ))
                      _DaySeparator(at: value.messages[i].createdAt),
                    _Bubble(
                      message: value.messages[i],
                      me: widget.user.id,
                      // Avatar et nom au premier message d'une série.
                      first:
                          i == 0 ||
                          value.messages[i - 1].authorId !=
                              value.messages[i].authorId,
                    ),
                  ],
                ],
              ),
            ),
            if (value.isClosed)
              const Padding(
                padding: EdgeInsets.all(16),
                child: AmpereInlineAlert(
                  tone: StatusTone.neutral,
                  message:
                      'Fil clos : il reste consultable, mais on n’y écrit plus.',
                ),
              )
            else
              _ReplyBar(
                controller: _reply,
                sending: _sending,
                error: _error,
                onSend: _send,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    final body = _reply.text.trim();
    if (body.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(conversationsApiProvider).reply(widget.id, body);
      _reply.clear();
      ref.invalidate(conversationProvider(widget.id));
    } on ApiException catch (error) {
      setState(() => _error = error.userMessage);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _close() async {
    try {
      await ref.read(conversationsApiProvider).close(widget.id);
      ref.invalidate(conversationProvider(widget.id));
    } on ApiException catch (error) {
      setState(() => _error = error.userMessage);
    }
  }
}

/// « Aujourd'hui », « Hier » ou la date, centré entre deux traits.
class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.at});

  final DateTime at;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final day = DateUtils.dateOnly(at.toLocal());
    final today = DateUtils.dateOnly(DateTime.now());
    final label = day == today
        ? 'Aujourd’hui'
        : day == today.subtract(const Duration(days: 1))
        ? 'Hier'
        : formatDate(day);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(child: Divider(color: colors.lineSoft)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
          ),
          Expanded(child: Divider(color: colors.lineSoft)),
        ],
      ),
    );
  }
}

/// Un message. Le mien à droite, plein dans la couleur d'accent ; celui des
/// autres à gauche, avec son avatar : on voit qui parle sans lire.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.me, this.first = true});

  final ConversationMessage message;
  final String me;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final mine = message.authorId == me;
    const r = Radius.circular(16);
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: mine ? colors.accent : colors.surface2,
        borderRadius: BorderRadius.only(
          topLeft: r,
          topRight: r,
          bottomLeft: mine ? r : const Radius.circular(4),
          bottomRight: mine ? const Radius.circular(4) : r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine && first)
            Text(
              message.authorName,
              style: AmpereType.label.copyWith(
                color: avatarColor(colors, message.authorName),
              ),
            ),
          Text(
            message.body,
            style: AmpereType.body.copyWith(
              color: mine ? colors.onAccent : colors.ink,
            ),
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: Text(
              formatTime(message.createdAt.toLocal()),
              style: AmpereType.meta.copyWith(
                fontSize: 11,
                color: mine
                    ? colors.onAccent.withValues(alpha: 0.75)
                    : colors.ink3,
              ),
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: 6, top: first ? 6 : 0),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine) ...[
            first
                ? PersonAvatar(name: message.authorName, size: 30)
                : const SizedBox(width: 30),
            const SizedBox(width: 8),
          ],
          Flexible(child: bubble),
        ],
      ),
    );
  }
}

class _ReplyBar extends StatelessWidget {
  const _ReplyBar({
    required this.controller,
    required this.sending,
    required this.error,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final String? error;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Column(
        children: [
          if (error case final error?) ...[
            AmpereInlineAlert(message: error),
            const SizedBox(height: 8),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: 'Écrire un message…',
                    counterText: '',
                  ),
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 2000,
                  onSubmitted: (_) => sending ? null : onSend(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: sending ? null : onSend,
                child: const Icon(LucideIcons.send, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
