import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Choix du thème, **persisté par utilisateur** (`docs/design-system.md` §2) :
/// sur le poste partagé du magasin, chacun retrouve le sien. Avant connexion,
/// l'app est dans le thème par défaut — **sombre** (§2.1/§2.3).
///
/// Rangé dans les réglages locaux (`LocalSettingsStore`), pas dans le stockage
/// sécurisé : ce n'est pas un secret.
class ThemeModeController extends Notifier<ThemeMode> {
  /// Posé dès que l'utilisateur choisit : la lecture asynchrone de la valeur
  /// stockée, si elle arrive APRÈS, ne doit pas écraser ce choix (course).
  bool _chosen = false;

  static String _key(String userId) => 'theme_mode.$userId';

  @override
  ThemeMode build() {
    _chosen = false;
    final userId = ref.watch(currentUserIdProvider);
    // Lecture asynchrone : on démarre en sombre (le défaut) et on corrige dès
    // que la valeur stockée est connue, sans faire attendre le premier rendu.
    if (userId != null) _restore(userId);
    return ThemeMode.dark;
  }

  Future<void> _restore(String userId) async {
    final stored = await ref.read(localSettingsStoreProvider).read(_key(userId));
    final mode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => null,
    };
    // L'utilisateur a-t-il changé entre-temps (déconnexion, autre compte), ou
    // déjà choisi un thème ? Alors cette lecture est périmée.
    if (_chosen || ref.read(currentUserIdProvider) != userId) return;
    if (mode != null && mode != state) state = mode;
  }

  Future<void> set(ThemeMode mode) async {
    _chosen = true;
    state = mode;
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    await ref
        .read(localSettingsStoreProvider)
        .write(_key(userId), mode == ThemeMode.light ? 'light' : 'dark');
  }

  Future<void> toggle() =>
      set(state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
}

final themeModeProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);
