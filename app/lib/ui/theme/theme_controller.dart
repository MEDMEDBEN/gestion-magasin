import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/local/app_database.dart';

/// Choix du thème, **persisté par utilisateur** (`docs/design-system.md` §2).
///
/// Stocké dans `LocalSettings` (Drift) et non dans le stockage sécurisé :
/// ce n'est pas un secret, et la table existe déjà pour ce genre de réglage.
/// Le thème **sombre est le défaut** (§2.1/§2.3).
class ThemeModeController extends Notifier<ThemeMode> {
  static const _key = 'theme_mode';

  @override
  ThemeMode build() {
    // Lecture asynchrone : on démarre en sombre (le défaut) et on corrige dès
    // que la valeur stockée est connue, sans faire attendre le premier rendu.
    _restore();
    return ThemeMode.dark;
  }

  Future<void> _restore() async {
    final stored = await _read();
    if (stored != null && stored != state) state = stored;
  }

  Future<ThemeMode?> _read() async {
    final db = ref.read(appDatabaseProvider);
    final row = await (db.select(db.localSettings)
          ..where((t) => t.key.equals(_key)))
        .getSingleOrNull();
    return switch (row?.value) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => null,
    };
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final db = ref.read(appDatabaseProvider);
    await db.into(db.localSettings).insertOnConflictUpdate(
          LocalSettingsCompanion.insert(
            key: _key,
            value: mode == ThemeMode.light ? 'light' : 'dark',
          ),
        );
  }

  Future<void> toggle() =>
      set(state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
}

final themeModeProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);
