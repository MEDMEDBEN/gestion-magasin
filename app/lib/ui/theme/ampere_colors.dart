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

  /// §2.3 — mobile sombre. Depuis le 2026-10-27 (demande MEDMEDBEN) : NOIR
  /// zinc, l'exact opposé du clair — texte blanc, action principale blanche,
  /// aucun bleu de thème ; la couleur reste aux états.
  static const mobileDark = AmpereColors(
    bg: Color(0xFF09090B),
    bgAlt: Color(0xFF09090B),
    surface: Color(0xFF111113),
    surface2: Color(0xFF18181B),
    surface3: Color(0xFF27272A),
    line: Color(0xFF27272A),
    lineSoft: Color(0xFF1C1C1F),
    ink: Color(0xFFFAFAFA),
    ink2: Color(0xFFA1A1AA),
    ink3: Color(0xFF8B8B94),
    accent: Color(0xFFFAFAFA),
    accentHi: Color(0xFFE4E4E7),
    accentBg: Color(0xFF27272A),
    onAccent: Color(0xFF09090B),
    ok: Color(0xFF22C55E),
    okBg: Color(0xFF0D2818),
    warn: Color(0xFFF59E0B),
    warnBg: Color(0xFF2A1F0A),
    error: Color(0xFFF87171),
    errorBg: Color(0xFF2D1313),
    info: Color(0xFFD4D4D8),
    infoBg: Color(0xFF27272A),
    neutral: Color(0xFFA1A1AA),
    neutralBg: Color(0xFF27272A),
    vizAlt: Color(0xFF71717A),
    scrim: Color(0xB3000000),
  );

  /// §2.4 — mobile clair.
  /// Clair NEUTRE (maquette « shadcn » fournie par MEDMEDBEN le 2026-10-26) :
  /// fond presque blanc, cartes blanches à filet fin, noir et gris zinc ; la
  /// couleur ne sert qu'aux états (petites pastilles, tendances).
  static const mobileLight = AmpereColors(
    bg: Color(0xFFFAFAFA),
    bgAlt: Color(0xFFFAFAFA),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF4F4F5),
    surface3: Color(0xFFE4E4E7),
    line: Color(0xFFE4E4E7),
    lineSoft: Color(0xFFF0F0F2),
    ink: Color(0xFF09090B),
    ink2: Color(0xFF52525B),
    ink3: Color(0xFF71717A),
    accent: Color(0xFF18181B),
    accentHi: Color(0xFF27272A),
    accentBg: Color(0xFFF4F4F5),
    onAccent: Color(0xFFFFFFFF),
    ok: Color(0xFF16A34A),
    okBg: Color(0xFFF0FDF4),
    warn: Color(0xFFD97706),
    warnBg: Color(0xFFFFFBEB),
    error: Color(0xFFDC2626),
    errorBg: Color(0xFFFEF2F2),
    info: Color(0xFF2563EB),
    infoBg: Color(0xFFEFF6FF),
    neutral: Color(0xFF52525B),
    neutralBg: Color(0xFFF4F4F5),
    vizAlt: Color(0xFFA1A1AA),
    scrim: Color(0xA804070B),
  );

  /// §2.1 — desktop sombre : même noir zinc que le mobile (2026-10-27).
  static const desktopDark = AmpereColors(
    bg: Color(0xFF09090B),
    bgAlt: Color(0xFF09090B),
    surface: Color(0xFF111113),
    surface2: Color(0xFF18181B),
    surface3: Color(0xFF27272A),
    line: Color(0xFF27272A),
    lineSoft: Color(0xFF1C1C1F),
    ink: Color(0xFFFAFAFA),
    ink2: Color(0xFFA1A1AA),
    ink3: Color(0xFF8B8B94),
    accent: Color(0xFFFAFAFA),
    accentHi: Color(0xFFE4E4E7),
    accentBg: Color(0xFF27272A),
    onAccent: Color(0xFF09090B),
    ok: Color(0xFF22C55E),
    okBg: Color(0xFF0D2818),
    warn: Color(0xFFF59E0B),
    warnBg: Color(0xFF2A1F0A),
    error: Color(0xFFF87171),
    errorBg: Color(0xFF2D1313),
    info: Color(0xFFD4D4D8),
    infoBg: Color(0xFF27272A),
    neutral: Color(0xFFA1A1AA),
    neutralBg: Color(0xFF27272A),
    vizAlt: Color(0xFF71717A),
    scrim: Color(0xB3000000),
  );

  /// §2.2 — desktop clair (accents assombris pour tenir le contraste ;
  /// ce n'est PAS une inversion du thème sombre).
  static const desktopLight = AmpereColors(
    bg: Color(0xFFFAFAFA),
    bgAlt: Color(0xFFFAFAFA),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF4F4F5),
    surface3: Color(0xFFE4E4E7),
    line: Color(0xFFE4E4E7),
    lineSoft: Color(0xFFF0F0F2),
    ink: Color(0xFF09090B),
    ink2: Color(0xFF52525B),
    ink3: Color(0xFF71717A),
    accent: Color(0xFF18181B),
    accentHi: Color(0xFF27272A),
    accentBg: Color(0xFFF4F4F5),
    onAccent: Color(0xFFFFFFFF),
    ok: Color(0xFF16A34A),
    okBg: Color(0xFFF0FDF4),
    warn: Color(0xFFD97706),
    warnBg: Color(0xFFFFFBEB),
    error: Color(0xFFDC2626),
    errorBg: Color(0xFFFEF2F2),
    info: Color(0xFF2563EB),
    infoBg: Color(0xFFEFF6FF),
    neutral: Color(0xFF52525B),
    neutralBg: Color(0xFFF4F4F5),
    vizAlt: Color(0xFFA1A1AA),
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
