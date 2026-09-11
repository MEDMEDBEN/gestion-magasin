import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/auth_controller.dart';

/// Changement de mot de passe. Deux usages, un seul écran :
/// - **forcé** à la première connexion (`mustChangePassword`, règle 14) : le
///   serveur refuse TOUTE autre route tant que ce n'est pas fait, donc pas de
///   retour possible ;
/// - **volontaire** depuis le profil : l'utilisateur peut renoncer.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key, this.forced = true});

  /// Vrai quand l'app y a été redirigée par `mustChangePassword`.
  final bool forced;

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;

  /// État LOCAL de l'envoi : l'état global de session ne passe jamais en
  /// chargement pour un changement de mot de passe (revue C9), et une erreur
  /// ne survit pas à la fermeture de l'écran.
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) return;

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).changePassword(
            currentPassword: _current.text,
            newPassword: _next.text,
          );
    } on ApiException catch (error) {
      _fail(error.userMessage);
      return;
    } catch (_) {
      _fail('Changement impossible. Réessayez.');
      return;
    }

    if (!mounted) return;
    // Forcé : le routeur quitte cet écran de lui-même (mustChangePassword levé).
    if (!widget.forced && Navigator.of(context).canPop()) {
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Mot de passe modifié.')),
      );
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final isLoading = _submitting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mot de passe'),
        automaticallyImplyLeading: !widget.forced,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.forced)
                    const AmpereInlineAlert(
                      tone: StatusTone.warn,
                      icon: LucideIcons.shield,
                      message: 'Votre mot de passe est temporaire. '
                          'Choisissez-en un nouveau pour accéder à l’application.',
                    )
                  else
                    Text(
                      'Choisissez un nouveau mot de passe. '
                      'Vos autres appareils devront se reconnecter.',
                      style: AmpereType.body.copyWith(color: colors.ink2),
                    ),
                  const SizedBox(height: 22),

                  const AmpereFieldLabel('Mot de passe actuel'),
                  TextFormField(
                    controller: _current,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !isLoading,
                    style: AmpereType.input.copyWith(color: colors.ink),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(LucideIcons.lock, size: 17),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        tooltip: _obscure ? 'Afficher' : 'Masquer',
                        icon: Icon(
                          _obscure ? LucideIcons.eyeOff : LucideIcons.eye,
                          size: 17,
                        ),
                      ),
                    ),
                    validator: (v) => (v == null || v.isEmpty)
                        ? 'Saisissez le mot de passe actuel'
                        : null,
                  ),
                  const SizedBox(height: 16),

                  const AmpereFieldLabel('Nouveau mot de passe'),
                  TextFormField(
                    controller: _next,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 128,
                    enabled: !isLoading,
                    style: AmpereType.input.copyWith(color: colors.ink),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(LucideIcons.keyRound, size: 17),
                      helperText: '8 caractères minimum',
                      counterText: '',
                    ),
                    validator: (v) {
                      if (v == null || v.length < 8) {
                        return 'Au moins 8 caractères';
                      }
                      // Le serveur refuse aussi ce cas — on l'attrape avant.
                      if (v == _current.text) {
                        return 'Doit être différent du mot de passe actuel';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  const AmpereFieldLabel('Confirmer'),
                  TextFormField(
                    controller: _confirm,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !isLoading,
                    style: AmpereType.input.copyWith(color: colors.ink),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(LucideIcons.keyRound, size: 17),
                    ),
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) =>
                        v != _next.text ? 'Les mots de passe diffèrent' : null,
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    AmpereInlineAlert(message: _error!),
                  ],

                  const SizedBox(height: 22),
                  SizedBox(
                    height: AmpereGeometry.touchPrimary,
                    child: FilledButton(
                      onPressed: isLoading ? null : _submit,
                      child: isLoading
                          ? SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colors.onAccent,
                              ),
                            )
                          : const Text('Valider'),
                    ),
                  ),

                  if (widget.forced) ...[
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: isLoading
                          ? null
                          : () =>
                              ref.read(authControllerProvider.notifier).logout(),
                      icon: const Icon(LucideIcons.logOut, size: 17),
                      label: const Text('Se déconnecter'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
