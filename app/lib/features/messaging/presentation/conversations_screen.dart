import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../ui/widgets/page_kit.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/contact_profile.dart' show initialsOf;
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../application/conversations_controller.dart';
import '../data/conversation_models.dart';
import '../data/conversations_api.dart';
import 'conversation_form.dart';
import 'conversation_thread.dart';

/// Communication interne (spec §25), présentée comme une messagerie
/// (demande MEDMEDBEN du 2026-10-13) : l'équipe en avatars en haut — un geste
/// pour écrire à quelqu'un —, puis les discussions, la plus récente en tête.
///
/// Toujours pas de pièce jointe ni d'édition : « une opération métier
/// structurée ne doit jamais être remplacée par un message ».
class ConversationsScreen extends ConsumerStatefulWidget {
  const ConversationsScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<ConversationsScreen> createState() =>
      _ConversationsScreenState();
}

class _ConversationsScreenState extends ConsumerState<ConversationsScreen> {
  bool _includeClosed = false;

  /// Écrire à UN membre : sa discussion privée ouverte s'il y en a une, sinon
  /// une nouvelle (le sujet est posé pour lui).
  Future<void> _chatWith(
    ConversationRecipient member,
    List<Conversation> threads,
  ) async {
    final existing = threads.where(
      (t) =>
          !t.isClosed &&
          t.participants.length == 2 &&
          t.participants.any((p) => p.userId == member.id),
    );
    if (existing.isNotEmpty) {
      await _open(existing.first.id);
      return;
    }
    final body = await showDialog<String>(
      context: context,
      builder: (_) => _FirstMessageDialog(name: member.fullName),
    );
    if (body == null || !mounted) return;
    try {
      final thread = await ref
          .read(conversationsApiProvider)
          .create(
            subject: '${widget.user.fullName} · ${member.fullName}',
            participantIds: [member.id],
            body: body,
          );
      ref.invalidate(conversationsProvider(false));
      ref.invalidate(conversationsProvider(true));
      if (mounted) await _open(thread.id);
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.userMessage)));
      }
    }
  }

  Future<void> _open(String id) async {
    await openConversationThread(context, id, widget.user);
    // De retour du fil : les non-lus ont bougé, la liste doit suivre.
    ref.invalidate(conversationsProvider(true));
    ref.invalidate(conversationsProvider(false));
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final threads = ref.watch(conversationsProvider(_includeClosed));
    final members = ref.watch(conversationRecipientsProvider).value ?? const [];
    final others = [
      for (final m in members)
        if (m.id != widget.user.id) m,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (others.isNotEmpty)
          Container(
            padding: EdgeInsets.fromLTRB(margin, 12, margin, 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.lineSoft)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ÉQUIPE — touchez quelqu’un pour lui écrire',
                  style: AmpereType.label.copyWith(color: colors.ink3),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 78,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final m in others)
                        _MemberAvatar(
                          name: m.fullName,
                          onTap: () => _chatWith(
                            m,
                            threads.value?.data ?? const <Conversation>[],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 10, margin, 6),
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
                icon: const Icon(LucideIcons.users, size: 17),
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
                        'Touchez un membre de l’équipe ci-dessus pour lui '
                        'écrire. Pour demander de la marchandise, passez par '
                        'une demande de transfert.',
                    action: FilledButton.icon(
                      onPressed: () =>
                          openConversationForm(context, widget.user),
                      icon: const Icon(LucideIcons.plus, size: 17),
                      label: const Text('Nouveau fil'),
                    ),
                  )
                : ListView.separated(
                    padding: withNavBar(
                      context,
                      EdgeInsets.fromLTRB(margin, 4, margin, 24),
                    ),
                    itemCount: page.data.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: colors.lineSoft),
                    itemBuilder: (context, i) => _ThreadTile(
                      thread: page.data[i],
                      user: widget.user,
                      onTap: () => _open(page.data[i].id),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

/// Couleur stable d'une personne (même nom → même couleur partout).
Color avatarColor(AmpereColors colors, String name) {
  final palette = [
    colors.accent,
    colors.ok,
    colors.warn,
    colors.vizAlt,
    colors.info,
    colors.error,
  ];
  return palette[name.codeUnits.fold(0, (a, b) => a + b) % palette.length];
}

/// Pastille ronde aux initiales.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.name, this.size = 40});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final tone = avatarColor(colors, name);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tone.withValues(alpha: 0.18),
        border: Border.all(color: tone.withValues(alpha: 0.6)),
      ),
      child: Text(
        initialsOf(name),
        style: AmpereType.bodyStrong.copyWith(
          color: tone,
          fontSize: size * 0.36,
        ),
      ),
    );
  }
}

class _MemberAvatar extends StatelessWidget {
  const _MemberAvatar({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          width: 68,
          child: Column(
            children: [
              PersonAvatar(name: name, size: 46),
              const SizedBox(height: 6),
              Text(
                name.split(' ').first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AmpereType.meta.copyWith(color: colors.ink2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({
    required this.thread,
    required this.user,
    required this.onTap,
  });

  final Conversation thread;
  final AuthUser user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final others = thread.participants
        .where((p) => p.userId != user.id)
        .map((p) => p.fullName)
        .toList();
    final who = others.isEmpty ? 'Fil personnel' : others.join(', ');
    final unread = thread.unread > 0;
    final today = DateUtils.dateOnly(DateTime.now());
    final at = thread.lastMessageAt.toLocal();
    final when = DateUtils.dateOnly(at) == today
        ? formatTime(at)
        : formatDate(at);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            others.length > 1
                ? CircleAvatar(
                    radius: 22,
                    backgroundColor: colors.accentBg,
                    child: Icon(
                      LucideIcons.users,
                      size: 18,
                      color: colors.accent,
                    ),
                  )
                : PersonAvatar(name: others.isEmpty ? user.fullName : who),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    who,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.rowTitle.copyWith(
                      color: colors.ink,
                      fontWeight: unread ? FontWeight.w700 : null,
                    ),
                  ),
                  Text(
                    thread.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.meta.copyWith(
                      color: unread ? colors.ink : colors.ink3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  when,
                  style: AmpereType.meta.copyWith(
                    color: unread ? colors.accent : colors.ink3,
                  ),
                ),
                const SizedBox(height: 4),
                if (thread.isClosed)
                  const AmpereBadge(label: 'Clos', tone: StatusTone.neutral)
                else if (unread)
                  Tooltip(
                    message: '${thread.unread} non lu(s)',
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 22),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colors.accent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${thread.unread}',
                        textAlign: TextAlign.center,
                        style: AmpereType.label.copyWith(
                          color: colors.onAccent,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Premier message d'une discussion privée.
class _FirstMessageDialog extends StatefulWidget {
  const _FirstMessageDialog({required this.name});

  final String name;

  @override
  State<_FirstMessageDialog> createState() => _FirstMessageDialogState();
}

class _FirstMessageDialogState extends State<_FirstMessageDialog> {
  final _body = TextEditingController();

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  void _send() {
    final text = _body.text.trim();
    if (text.isNotEmpty) Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        PersonAvatar(name: widget.name, size: 34),
        const SizedBox(width: 10),
        Expanded(child: Text(widget.name)),
      ],
    ),
    content: SizedBox(
      width: 420,
      child: TextField(
        controller: _body,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        maxLength: 2000,
        decoration: const InputDecoration(hintText: 'Votre message'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Annuler'),
      ),
      FilledButton.icon(
        onPressed: _send,
        icon: const Icon(LucideIcons.send, size: 16),
        label: const Text('Envoyer'),
      ),
    ],
  );
}

/// Exposé pour l'écran du fil : répondre puis recharger.
Future<void> replyTo(WidgetRef ref, String id, String body) async {
  await ref.read(conversationsApiProvider).reply(id, body);
  ref.invalidate(conversationProvider(id));
}
