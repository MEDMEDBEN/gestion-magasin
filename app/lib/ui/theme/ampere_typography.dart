import 'package:flutter/material.dart';

/// Typographie AMPÈRE (`docs/design-system.md` §3) — famille unique **Archivo**,
/// bundlée en asset (§11). Deux échelles : desktop §3.1, mobile §3.2.
class AmpereType {
  const AmpereType._();

  static const String family = 'Archivo';

  /// `tnum` : chiffres tabulaires. Obligatoire sur TOUT nombre (§3), sans quoi
  /// une colonne de montants ne s'aligne pas.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  // ── Mobile (§3.2) ─────────────────────────────────────────────────────────
  static const screenTitle =
      TextStyle(fontSize: 23, height: 1.2, fontWeight: FontWeight.w800);
  static const sectionTitle =
      TextStyle(fontSize: 17, height: 1.25, fontWeight: FontWeight.w800);
  static const numericHero = TextStyle(
    fontSize: 34,
    height: 1.1,
    fontWeight: FontWeight.w700,
    fontFeatures: tabular,
  );
  static const numeric = TextStyle(
    fontSize: 24,
    height: 1.1,
    fontWeight: FontWeight.w700,
    fontFeatures: tabular,
  );
  static const rowTitle =
      TextStyle(fontSize: 14.5, height: 1.35, fontWeight: FontWeight.w600);
  static const body =
      TextStyle(fontSize: 15, height: 1.55, fontWeight: FontWeight.w400);
  static const meta =
      TextStyle(fontSize: 12.5, height: 1.5, fontWeight: FontWeight.w400);
  static const label = TextStyle(
    fontSize: 10.5,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.47, // .14em
  );

  /// 16 px minimum dans un champ : en dessous, iOS zoome à la saisie (§3.2).
  static const input =
      TextStyle(fontSize: 16, height: 1.3, fontWeight: FontWeight.w600);

  // ── Desktop (§3.1) ────────────────────────────────────────────────────────
  static const h1 = TextStyle(
    fontSize: 26,
    height: 1.15,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.78,
  );
  static const h2 = TextStyle(
    fontSize: 21,
    height: 1.2,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.42,
  );
  static const h3 = TextStyle(
    fontSize: 19,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.38,
  );
  static const h4 = TextStyle(
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.32,
  );
  static const cardTitle =
      TextStyle(fontSize: 14.5, height: 1.35, fontWeight: FontWeight.w600);
  static const bodyDesktop =
      TextStyle(fontSize: 13.5, height: 1.5, fontWeight: FontWeight.w400);
  static const bodyStrong =
      TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w600);
  static const metaDesktop =
      TextStyle(fontSize: 11.5, height: 1.45, fontWeight: FontWeight.w400);
  static const labelDesktop = TextStyle(
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.4, // .14em
  );
  static const mono = TextStyle(
    fontSize: 11.5,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.23,
    fontFeatures: tabular,
  );
}

/// Géométrie et mouvement (§4). Une seule source pour les rayons : un rayon
/// hors de cette liste est interdit (§12.8).
class AmpereGeometry {
  const AmpereGeometry._();

  // Rayons — desktop / mobile.
  static const double cardRadiusDesktop = 12;
  static const double cardRadiusMobile = 14;
  static const double fieldRadiusDesktop = 8;
  static const double fieldRadiusMobile = 10;
  static const double iconChipRadius = 11;
  static const double sheetRadius = 20;
  static const double pillRadius = 999;

  /// Une seule épaisseur de bordure dans tout le système.
  static const double borderWidth = 1;

  // Cibles tactiles (§7) — un plancher, pas une suggestion (§12.5).
  static const double touchMin = 44;
  static const double touchDefault = 48;
  static const double touchPrimary = 52;
  static const double listRowMin = 56;
  static const double fieldHeightMobile = 52;
  static const double fieldHeightDesktop = 38;
  static const double buttonHeightDesktop = 36;
  static const double buttonHeightForm = 40;

  // Marges (§4).
  static const double screenMarginDesktop = 20;
  static const double screenMarginMobile = 16;
  static const double cardPaddingDesktop = 16;
  static const double cardPaddingMobile = 14;

  // Mouvement (§4) — rien d'autre n'est animé.
  static const Duration enter = Duration(milliseconds: 140);
  static const Duration sheet = Duration(milliseconds: 200);
  static const Duration hover = Duration(milliseconds: 100);
  static const Duration skeleton = Duration(milliseconds: 1400);
}
