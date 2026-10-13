import 'package:flutter/material.dart';

/// Jetons de couleur du design system AMPÈRE (`docs/design-system.md` §2).
///
/// Aucun widget ne connaît le thème actif : il lit `AmpereColors.of(context)`.
/// Quatre palettes portent les MÊMES noms — desktop sombre/clair (§2.1/§2.2) et
/// mobile sombre/clair (§2.3/§2.4) — parce que le produit est un seul code
/// Flutter pour les deux plateformes : la palette suit la taille de l'écran.
@immutable
class AmpereColors extends ThemeExtension<AmpereColors> {
  const AmpereColors({
    required this.bg,
    required this.bgAlt,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.line,
    required this.lineSoft,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.accent,
    required this.accentHi,
    required this.accentBg,
    required this.onAccent,
    required this.ok,
    required this.okBg,
    required this.warn,
    required this.warnBg,
    required this.error,
    required this.errorBg,
    required this.info,
    required this.infoBg,
    required this.neutral,
    required this.neutralBg,
    required this.vizAlt,
    required this.scrim,
  });

  final Color bg;
  final Color bgAlt;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color line;
  final Color lineSoft;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color accent;
  final Color accentHi;
  final Color accentBg;
  final Color onAccent;
  final Color ok;
  final Color okBg;
  final Color warn;
  final Color warnBg;
  final Color error;
  final Color errorBg;
  final Color info;
  final Color infoBg;
  final Color neutral;
  final Color neutralBg;
  final Color vizAlt;

  /// Voile posé derrière une couche flottante (dialogue, panneau, feuille) —
  /// « scène » de §6 (desktop, rgba(3,7,14,.62)) et §7 (mobile, rgba(4,7,11,.66)).
  final Color scrim;

  static AmpereColors of(BuildContext context) =>
      Theme.of(context).extension<AmpereColors>()!;

  /// §2.3 — mobile sombre (défaut : bleu nuit plus chaud, accent plus cyan).
  static const mobileDark = AmpereColors(
    bg: Color(0xFF0B1017),
    bgAlt: Color(0xFF070B12),
    surface: Color(0xFF121A24),
    surface2: Color(0xFF18222E),
    surface3: Color(0xFF1E2A38),
    line: Color(0xFF223141),
    lineSoft: Color(0xFF1A2532),
    ink: Color(0xFFE9EFF6),
    ink2: Color(0xFF93A5B8),
    ink3: Color(0xFF63768A),
    accent: Color(0xFF2FA8FF),
    accentHi: Color(0xFF7CD0FF),
    accentBg: Color(0xFF0E2436),
    onAccent: Color(0xFF04121D),
    ok: Color(0xFF10B981),
    okBg: Color(0xFF0B2A24),
    warn: Color(0xFFF59E0B),
    warnBg: Color(0xFF2E2210),
    error: Color(0xFFF43F5E),
    errorBg: Color(0xFF33141E),
    info: Color(0xFF818CF8),
    infoBg: Color(0xFF1C1E3F),
    neutral: Color(0xFF93A5B8),
    neutralBg: Color(0xFF1E2A38),
    vizAlt: Color(0xFF8B7CF6),
    scrim: Color(0xA804070B),
  );

  /// §2.4 — mobile clair.
  /// Clair MONOCHROME (maquette fournie par MEDMEDBEN le 2026-10-13) : fond
  /// gris perle, cartes blanches très arrondies, l'actif en NOIR (pastilles et
  /// boutons pilule), la couleur gardée pour les états seulement.
  static const mobileLight = AmpereColors(
    bg: Color(0xFFE9E9EC),
    bgAlt: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF3F3F5),
    surface3: Color(0xFFE7E7EA),
    line: Color(0xFFE0E0E4),
    lineSoft: Color(0xFFEDEDF0),
    ink: Color(0xFF111113),
    ink2: Color(0xFF4A4A50),
    ink3: Color(0xFF8A8A92),
    accent: Color(0xFF111113),
    accentHi: Color(0xFF2A2A2E),
    accentBg: Color(0xFFECECEF),
    onAccent: Color(0xFFFFFFFF),
    ok: Color(0xFF059669),
    okBg: Color(0xFFD1FAE5),
    warn: Color(0xFFEA580C),
    warnBg: Color(0xFFFFEDD5),
    error: Color(0xFFE11D48),
    errorBg: Color(0xFFFFE4E6),
    info: Color(0xFF4F46E5),
    infoBg: Color(0xFFE0E7FF),
    neutral: Color(0xFF5C5C64),
    neutralBg: Color(0xFFEFEFF2),
    vizAlt: Color(0xFF6D5BD0),
    scrim: Color(0xA804070B),
  );

  /// §2.1 — desktop sombre (défaut).
  static const desktopDark = AmpereColors(
    bg: Color(0xFF0A0F19),
    bgAlt: Color(0xFF070B12),
    surface: Color(0xFF111A29),
    surface2: Color(0xFF16202F),
    surface3: Color(0xFF16202F),
    line: Color(0xFF22304A),
    lineSoft: Color(0xFF1A2537),
    ink: Color(0xFFE8EEF8),
    ink2: Color(0xFF93A2BD),
    ink3: Color(0xFF63748F),
    accent: Color(0xFF2F7DF6),
    accentHi: Color(0xFF5AA0FF),
    accentBg: Color(0xFF12233D),
    onAccent: Color(0xFFFFFFFF),
    ok: Color(0xFF10B981),
    okBg: Color(0xFF0B2A24),
    warn: Color(0xFFF59E0B),
    warnBg: Color(0xFF2E2210),
    error: Color(0xFFF43F5E),
    errorBg: Color(0xFF33141E),
    info: Color(0xFF818CF8),
    infoBg: Color(0xFF1C1E3F),
    neutral: Color(0xFF93A2BD),
    neutralBg: Color(0xFF16202F),
    vizAlt: Color(0xFF8B7CF6),
    scrim: Color(0x9E03070E),
  );

  /// §2.2 — desktop clair (accents assombris pour tenir le contraste ;
  /// ce n'est PAS une inversion du thème sombre).
  static const desktopLight = AmpereColors(
    bg: Color(0xFFE9E9EC),
    bgAlt: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF3F3F5),
    surface3: Color(0xFFE7E7EA),
    line: Color(0xFFE0E0E4),
    lineSoft: Color(0xFFEDEDF0),
    ink: Color(0xFF111113),
    ink2: Color(0xFF4A4A50),
    ink3: Color(0xFF8A8A92),
    accent: Color(0xFF111113),
    accentHi: Color(0xFF2A2A2E),
    accentBg: Color(0xFFECECEF),
    onAccent: Color(0xFFFFFFFF),
    ok: Color(0xFF059669),
    okBg: Color(0xFFD1FAE5),
    warn: Color(0xFFEA580C),
    warnBg: Color(0xFFFFEDD5),
    error: Color(0xFFE11D48),
    errorBg: Color(0xFFFFE4E6),
    info: Color(0xFF4F46E5),
    infoBg: Color(0xFFE0E7FF),
    neutral: Color(0xFF5C5C64),
    neutralBg: Color(0xFFEFEFF2),
    vizAlt: Color(0xFF6D5BD0),
    scrim: Color(0x9E03070E),
  );

  @override
  AmpereColors copyWith() => this;

  /// Les palettes sont discrètes : on bascule d'un thème à l'autre sans
  /// interpoler des couleurs intermédiaires qui n'existent pas dans le système.
  @override
  AmpereColors lerp(ThemeExtension<AmpereColors>? other, double t) =>
      t < 0.5 ? this : (other as AmpereColors? ?? this);
}

/// Un couple (ton de trait/texte, fond désaturé) — §2.5 : les deux vont TOUJOURS
/// ensemble, et la couleur ne porte jamais l'information seule (§12.4).
enum StatusTone { ok, warn, error, info, neutral }

extension StatusToneColors on StatusTone {
  /// Dégradé VIF de l'état (même famille que le tableau de bord, 2026-10-14) :
  /// pour ce qui est mis en avant (action principale, filtre choisi).
  LinearGradient gradient() => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: switch (this) {
      StatusTone.ok => const [Color(0xFF06B6D4), Color(0xFF10B981)],
      StatusTone.info => const [Color(0xFF6366F1), Color(0xFF3B82F6)],
      StatusTone.warn => const [Color(0xFFF59E0B), Color(0xFFF97316)],
      StatusTone.error => const [Color(0xFFF43F5E), Color(0xFFD946EF)],
      StatusTone.neutral => const [Color(0xFF64748B), Color(0xFF475569)],
    },
  );

  Color foreground(AmpereColors c) => switch (this) {
    StatusTone.ok => c.ok,
    StatusTone.warn => c.warn,
    StatusTone.error => c.error,
    StatusTone.info => c.info,
    StatusTone.neutral => c.neutral,
  };

  Color background(AmpereColors c) => switch (this) {
    StatusTone.ok => c.okBg,
    StatusTone.warn => c.warnBg,
    StatusTone.error => c.errorBg,
    StatusTone.info => c.infoBg,
    StatusTone.neutral => c.neutralBg,
  };
}
