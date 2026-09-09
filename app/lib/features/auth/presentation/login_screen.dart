import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/theme/app_theme.dart';
import '../application/auth_controller.dart';

/// Écran de connexion — commun desktop et mobile : un formulaire centré,
/// borné en largeur, fonctionne bien sur les deux. Les écrans qui divergent
/// vraiment vivent dans `ui/desktop` et `ui/mobile`.
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
    final auth = ref.watch(authControllerProvider);
    final isLoading = auth.isLoading;

    // Erreur de connexion, ou motif d'une déconnexion subie (session expirée).
    final signedOutMessage = switch (auth.value) {
      AuthSignedOut(:final message) => message,
      _ => null,
    };
    final errorText = auth.hasError
        ? _messageFor(auth.error!)
        : signedOutMessage;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Touche d'identité électrique, discrète.
                  const Icon(
                    Icons.electrical_services,
                    size: 48,
                    color: AppColors.accent,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Gestion magasin',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Matériel électrique — magasin & dépôt',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _identifier,
                    autofocus: true,
                    enabled: !isLoading,
                    decoration: const InputDecoration(
                      labelText: 'Email ou téléphone',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                            ? 'Saisissez votre identifiant'
                            : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _password,
                    enabled: !isLoading,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Mot de passe',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
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
                    Text(
                      errorText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.danger),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: isLoading ? null : _submit,
                    child: isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Se connecter'),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "Votre compte est créé par l'administrateur.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// On n'affiche jamais un message technique brut à l'utilisateur.
  String _messageFor(Object error) => switch (error) {
        ApiException(:final userMessage) => userMessage,
        _ => 'Connexion impossible',
      };
}
