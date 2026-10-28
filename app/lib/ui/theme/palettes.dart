import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'ampere_colors.dart';
import 'theme_controller.dart';

/// Palettes au choix (demande MEDMEDBEN du 2026-10-28) : les deux d'origine
/// (Clair, Bleu nuit) et quatre nouvelles — deux claires, deux sombres — aux
/// teintes vives mais LISIBLES (textes et boutons gardent leur contraste).
/// Chaque palette porte aussi les couleurs de ses LED de fond.
enum AppPalette {
  clair('Clair', dark: false),
  menthe('Menthe', dark: false),
  aurore('Aurore', dark: false),
  bleuNuit('Bleu nuit', dark: true),
  neon('Néon', dark: true),
  synthwave('Synthwave', dark: true);

  const AppPalette(this.label, {required this.dark});

  final String label;
  final bool dark;

  AmpereColors get desktop => switch (this) {
    clair => AmpereColors.desktopLight,
    bleuNuit => AmpereColors.desktopDark,
    menthe => _menthe,
    aurore => _aurore,
    neon => _neon,
    synthwave => _synthwave,
  };

  AmpereColors get mobile => switch (this) {
    clair => AmpereColors.mobileLight,
    bleuNuit => AmpereColors.mobileDark,
    _ => desktop,
  };

  /// Couleurs des LED quand elles « suivent la palette ».
  List<Color> get ledHues => switch (this) {
    clair ||
    bleuNuit => const [Color(0xFF5B7CFA), Color(0xFF2DD4BF), Color(0xFFA78BFA)],
    menthe => const [Color(0xFF19E68C), Color(0xFF00C2FF), Color(0xFFB6F23C)],
    aurore => const [Color(0xFFFF4F7B), Color(0xFFFFB020), Color(0xFFB26BFF)],
    neon => const [Color(0xFF2BFF9E), Color(0xFF4DD8FF), Color(0xFFC6FF3D)],
    synthwave => const [
      Color(0xFFFF3DCB),
      Color(0xFF4DC3FF),
      Color(0xFF9D5CFF),
    ],
  };

  /// Aperçu : fond, surface, accent.
  List<Color> get swatch => [desktop.bg, desktop.surface3, desktop.accent];
}

/// Menthe — clair, vert jade et menthe glacée.
const _menthe = AmpereColors(
  bg: Color(0xFFF3FAF6),
  bgAlt: Color(0xFFF3FAF6),
  surface: Color(0xFFFFFFFF),
  surface2: Color(0xFFEAF6EF),
  surface3: Color(0xFFD3EDDF),
  line: Color(0xFFD2E7DB),
  lineSoft: Color(0xFFE5F2EA),
  ink: Color(0xFF0B2A1E),
  ink2: Color(0xFF3D5C4E),
  ink3: Color(0xFF5B7769),
  accent: Color(0xFF00A86B),
  accentHi: Color(0xFF008A58),
  accentBg: Color(0xFFD7F7E8),
  onAccent: Color(0xFFFFFFFF),
  ok: Color(0xFF0A9A5B),
  okBg: Color(0xFFDCF7EA),
  warn: Color(0xFFD97706),
  warnBg: Color(0xFFFFF4DC),
  error: Color(0xFFE11D48),
  errorBg: Color(0xFFFFE6EC),
  info: Color(0xFF0E8FB8),
  infoBg: Color(0xFFDDF4FB),
  neutral: Color(0xFF4B6357),
  neutralBg: Color(0xFFEAF2EE),
  vizAlt: Color(0xFF00C2FF),
  scrim: Color(0x990B2A1E),
);

/// Aurore — clair, corail rosé sur pêche très pâle.
const _aurore = AmpereColors(
  bg: Color(0xFFFFF7F3),
  bgAlt: Color(0xFFFFF7F3),
  surface: Color(0xFFFFFFFF),
  surface2: Color(0xFFFFEFE8),
  surface3: Color(0xFFFADBCF),
  line: Color(0xFFF2DCD2),
  lineSoft: Color(0xFFF8E9E2),
  ink: Color(0xFF2A1220),
  ink2: Color(0xFF5E4250),
  ink3: Color(0xFF7E626C),
  accent: Color(0xFFE63E6D),
  accentHi: Color(0xFFC42E5A),
  accentBg: Color(0xFFFFE3EA),
  onAccent: Color(0xFFFFFFFF),
  ok: Color(0xFF13996B),
  okBg: Color(0xFFDDF5EA),
  warn: Color(0xFFD97706),
  warnBg: Color(0xFFFFF1DA),
  error: Color(0xFFB42318),
  errorBg: Color(0xFFFDE7E4),
  info: Color(0xFF6D4AFF),
  infoBg: Color(0xFFEEE9FF),
  neutral: Color(0xFF5E4250),
  neutralBg: Color(0xFFF6ECEE),
  vizAlt: Color(0xFFFFB020),
  scrim: Color(0x992A1220),
);

/// Néon — sombre, vert néon sur noir forêt.
const _neon = AmpereColors(
  bg: Color(0xFF07120F),
  bgAlt: Color(0xFF07120F),
  surface: Color(0xFF0D1C18),
  surface2: Color(0xFF12251F),
  surface3: Color(0xFF1A3029),
  line: Color(0xFF1E3A31),
  lineSoft: Color(0xFF142A23),
  ink: Color(0xFFE4F7EF),
  ink2: Color(0xFF93B8A9),
  ink3: Color(0xFF739A8C),
  accent: Color(0xFF2BFF9E),
  accentHi: Color(0xFF7CFFC4),
  accentBg: Color(0xFF0F3326),
  onAccent: Color(0xFF03140D),
  ok: Color(0xFF3DE89A),
  okBg: Color(0xFF0E2F22),
  warn: Color(0xFFFFC94D),
  warnBg: Color(0xFF2F2610),
  error: Color(0xFFFF5C8A),
  errorBg: Color(0xFF351420),
  info: Color(0xFF4DD8FF),
  infoBg: Color(0xFF0E2A35),
  neutral: Color(0xFF93B8A9),
  neutralBg: Color(0xFF1A3029),
  vizAlt: Color(0xFF4DD8FF),
  scrim: Color(0xB3020806),
);

/// Synthwave — sombre, magenta néon et cyan sur violet profond.
const _synthwave = AmpereColors(
  bg: Color(0xFF0E0920),
  bgAlt: Color(0xFF0E0920),
  surface: Color(0xFF160F2E),
  surface2: Color(0xFF1E163C),
  surface3: Color(0xFF291E4D),
  line: Color(0xFF2E2357),
  lineSoft: Color(0xFF1F1740),
  ink: Color(0xFFF2ECFF),
  ink2: Color(0xFFB3A6D9),
  ink3: Color(0xFF9183BD),
  accent: Color(0xFFFF3DCB),
  accentHi: Color(0xFFFF8AE2),
  accentBg: Color(0xFF3A1450),
  onAccent: Color(0xFF1B0624),
  ok: Color(0xFF2EF2C2),
  okBg: Color(0xFF0F2E2E),
  warn: Color(0xFFFFB13D),
  warnBg: Color(0xFF33240F),
  error: Color(0xFFFF4D6D),
  errorBg: Color(0xFF3A1222),
  info: Color(0xFF4DC3FF),
  infoBg: Color(0xFF142844),
  neutral: Color(0xFFB3A6D9),
  neutralBg: Color(0xFF291E4D),
  vizAlt: Color(0xFF4DC3FF),
  scrim: Color(0xB3060310),
);

/// Palette choisie, **par compte** sur le poste (comme le thème). `null` :
/// jamais choisie — on suit alors le réglage clair/sombre d'origine.
class PaletteController extends Notifier<AppPalette?> {
  bool _chosen = false;

  static String _key(String userId) => 'palette.$userId';

  @override
  AppPalette? build() {
    _chosen = false;
    final userId = ref.watch(currentUserIdProvider);
    if (userId != null) _restore(userId);
    return null;
  }

  Future<void> _restore(String userId) async {
    final stored = await ref
        .read(localSettingsStoreProvider)
        .read(_key(userId));
    if (_chosen || !ref.mounted || ref.read(currentUserIdProvider) != userId) {
      return;
    }
    final found = AppPalette.values.where((p) => p.name == stored).firstOrNull;
    if (found != null) state = found;
  }

  Future<void> set(AppPalette palette) async {
    _chosen = true;
    state = palette;
    // Le réglage clair/sombre suit (écran de profil, thème avant connexion).
    await ref
        .read(themeModeProvider.notifier)
        .set(palette.dark ? ThemeMode.dark : ThemeMode.light);
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    await ref
        .read(localSettingsStoreProvider)
        .write(_key(userId), palette.name);
  }
}

final paletteProvider = NotifierProvider<PaletteController, AppPalette?>(
  PaletteController.new,
);

/// La palette en vigueur : celle choisie, sinon Clair / Bleu nuit selon le
/// réglage clair/sombre.
AppPalette currentPalette(WidgetRef ref) =>
    ref.watch(paletteProvider) ??
    (ref.watch(themeModeProvider) == ThemeMode.light
        ? AppPalette.clair
        : AppPalette.bleuNuit);
