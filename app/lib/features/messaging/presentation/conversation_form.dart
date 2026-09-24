import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../application/conversations_controller.dart';
import '../data/conversations_api.dart';

Future<void> openConversationForm(BuildContext context, AuthUser user) =>
    openFormPanel<void>(context, ConversationForm(user: user));

/// Ouvrir un fil : un sujet, des destinataires, un premier message.
///
/// Le rappel de la spec §25 est affiché ICI, au moment où quelqu'un est tenté
/// d'écrire « il me faut 20 LED » au lieu de faire une demande de transfert.
class ConversationForm extends ConsumerStatefulWidget {
  const ConversationForm({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<ConversationForm> createState() => _ConversationFormState();
}

class _ConversationFormState extends ConsumerState<ConversationForm> {
  final _formKey = GlobalKey<FormState>();
  final _subject = TextEditingController();
  final _body = TextEditingController();
  final _selected = <String>{};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Annuaire DÉDIÉ (id + nom) : la liste des comptes est réservée à l'admin,
    // et s'en servir ici rendait le formulaire inutilisable pour deux rôles
    // sur trois (revue P1 n°17). Le serveur reste juge à l'envoi.
    final members = ref.watch(conversationRecipientsProvider);

    return FormPanelFrame(
      formKey: _formKey,
      title: 'Nouveau fil',
      submitLabel: 'Envoyer',
      saving: _saving,
      error: _error,
      onSubmit: _saving ? null : _submit,
      children: [
        const AmpereInlineAlert(
          tone: StatusTone.info,
          message:
              'Pour une question ou une consigne. Pour demander de la '
              'marchandise au dépôt, faites une demande de transfert : elle '
              'se suit et déplace vraiment le stock.',
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _subject,
          decoration: const InputDecoration(labelText: 'Sujet'),
          maxLength: 120,
          validator: (value) =>
              (value ?? '').trim().length < 2 ? 'Sujet trop court' : null,
        ),
        const SizedBox(height: 12),
        Text('Destinataires', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        switch (members) {
          AsyncError() => const AmpereInlineAlert(
            message: 'La liste des membres n’a pas pu être chargée.',
          ),
          AsyncValue(:final value?) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final member in value.where((m) => m.id != widget.user.id))
                FilterChip(
                  label: Text(member.fullName),
                  selected: _selected.contains(member.id),
                  onSelected: (on) => setState(
                    () => on
                        ? _selected.add(member.id)
                        : _selected.remove(member.id),
                  ),
                ),
            ],
          ),
          _ => const LinearProgressIndicator(),
        },
        const SizedBox(height: 16),
        TextFormField(
          controller: _body,
          decoration: const InputDecoration(labelText: 'Message'),
          minLines: 3,
          maxLines: 6,
          maxLength: 2000,
          validator: (value) =>
              (value ?? '').trim().isEmpty ? 'Message vide' : null,
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selected.isEmpty) {
      setState(() => _error = 'Choisissez au moins un destinataire.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(conversationsApiProvider)
          .create(
            subject: _subject.text.trim(),
            participantIds: _selected.toList(),
            body: _body.text.trim(),
          );
      ref.invalidate(conversationsProvider(false));
      ref.invalidate(conversationsProvider(true));
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (error) {
      setState(() {
        _saving = false;
        _error = error.userMessage;
      });
    }
  }
}
