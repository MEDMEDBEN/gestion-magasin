import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/auth_controller.dart';

/// Connexion — formulaire centré borné en largeur : la même mise en page tient
/// sur desktop et mobile. La palette, elle, suit la plateforme (AMPÈRE §2).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    await ref.read(authControllerProvider.notifier).login(
          identifier: _identifier.text.trim(),
          password: _password.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final auth = ref.watch(authControllerProvider);
    final isLoading = auth.isLoading;

    // Erreur de connexion, ou motif d'une déconnexion subie (session expirée).
    final signedOutMessage = switch (auth.value) {
      AuthSignedOut(:final message) => message,
      _ => null,
    };
    final errorText = auth.hasError ? _messageFor(auth.error!) : signedOutMessage;

    return Scaffold(
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
                  // `zap` est le SEUL éclair du système (AMPÈRE §5).
                  Align(
                    child: AmpereIconChip(
                      icon: LucideIcons.zap,
                      size: 56,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Gestion magasin',
                    textAlign: TextAlign.center,
                    style: AmpereType.screenTitle.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Matériel électrique — magasin & dépôt',
                    textAlign: TextAlign.center,
                    style: AmpereType.body.copyWith(color: colors.ink2),
                  ),
                  const SizedBox(height: 30),

                  const AmpereFieldLabel('Email ou téléphone'),
                  TextFormField(
                    controller: _identifier,
                    autofocus: true,
                    enabled: !isLoading,
                    // Un identifiant ne se corrige pas : l'autocorrection
                    // changerait « amine@magasin.dz » (contre-revue S14).
                    autocorrect: false,
                    enableSuggestions: false,
                    style: AmpereType.input.copyWith(color: colors.ink),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(LucideIcons.user, size: 17),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (value) => (value == null || value.trim().isEmpty)
                        ? 'Saisissez votre identifiant'
                        : null,
                  ),
                  const SizedBox(height: 16),

                  const AmpereFieldLabel('Mot de passe'),
                  TextFormField(
                    controller: _password,
                    enabled: !isLoading,
                    obscureText: _obscure,
                    // Rien ne doit mémoriser ni suggérer un mot de passe.
                    autocorrect: false,
                    enableSuggestions: false,
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
                    onFieldSubmitted: (_) => _submit(),
                    validator: (value) => (value == null || value.isEmpty)
                        ? 'Saisissez votre mot de passe'
                        : null,
                  ),

                  if (errorText != null) ...[
                    const SizedBox(height: 16),
                    AmpereInlineAlert(message: errorText),
                  ],

                  const SizedBox(height: 22),
                  // L'action principale, unique et en accent (§1.3).
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
                          : const Text('Se connecter'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "Votre compte est créé par l'administrateur.",
                    textAlign: TextAlign.center,
                    style: AmpereType.meta.copyWith(color: colors.ink3),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// On n'affiche jamais un message technique brut (§8 : dire ce qui s'est
  /// passé, pas le code).
  String _messageFor(Object error) => switch (error) {
        ApiException(:final userMessage) => userMessage,
        _ => 'Connexion impossible',
      };
}
