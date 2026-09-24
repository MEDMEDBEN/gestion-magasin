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
        title: Text(thread.value?.subject ?? 'Conversation'),
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
                  for (final message in value.messages)
                    _Bubble(message: message, me: widget.user.id),
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

/// Un message. Le mien est aligné à droite et coloré : on repère d'un coup
/// d'œil qui parle, sans lire les noms.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.me});

  final ConversationMessage message;
  final String me;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final mine = message.authorId == me;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: mine ? colors.accentBg : colors.surface2,
          borderRadius: BorderRadius.circular(AmpereGeometry.cardRadiusMobile),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${mine ? 'Moi' : message.authorName} · '
              '${formatDateTime(message.createdAt)}',
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
            const SizedBox(height: 4),
            Text(message.body, style: AmpereType.body),
          ],
        ),
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
                  decoration: const InputDecoration(hintText: 'Votre réponse'),
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
