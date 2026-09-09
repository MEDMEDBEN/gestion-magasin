import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/theme/app_theme.dart';
import '../application/auth_controller.dart';

/// Changement de mot de passe imposé à la première connexion (CLAUDE.md règle 14).
/// Tant qu'il n'est pas fait, le serveur refuse TOUTE autre route.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    await ref.read(authControllerProvider.notifier).changePassword(
          currentPassword: _current.text,
          newPassword: _next.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final isLoading = auth.isLoading;

    return Scaffold(
      appBar: AppBar(title: const Text('Changement de mot de passe')),
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
                  const Text(
                    'Votre mot de passe est temporaire. Choisissez-en un nouveau '
                    'pour accéder à l’application.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _current,
                    obscureText: true,
                    enabled: !isLoading,
                    decoration: const InputDecoration(
                      labelText: 'Mot de passe actuel',
                    ),
                    validator: (v) => (v == null || v.isEmpty)
                        ? 'Saisissez le mot de passe actuel'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _next,
                    obscureText: true,
                    enabled: !isLoading,
                    decoration: const InputDecoration(
                      labelText: 'Nouveau mot de passe',
                      helperText: '8 caractères minimum',
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
                  TextFormField(
                    controller: _confirm,
                    obscureText: true,
                    enabled: !isLoading,
                    decoration: const InputDecoration(
                      labelText: 'Confirmer le nouveau mot de passe',
                    ),
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) =>
                        v != _next.text ? 'Les mots de passe diffèrent' : null,
                  ),
                  if (auth.hasError) ...[
                    const SizedBox(height: 16),
                    Text(
                      switch (auth.error!) {
                        ApiException(:final userMessage) => userMessage,
                        _ => 'Changement impossible',
                      },
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
                        : const Text('Valider'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
