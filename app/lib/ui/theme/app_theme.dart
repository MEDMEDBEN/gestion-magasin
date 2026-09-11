import 'package:flutter/material.dart';

import 'ampere_colors.dart';
import 'ampere_typography.dart';

/// Assemble les jetons AMPÈRE en `ThemeData` (`docs/design-system.md` §11).
///
/// Thème **sombre par défaut**, clair disponible, choix persisté par utilisateur.
/// La palette dépend AUSSI de la taille : desktop et mobile n'ont pas les mêmes
/// valeurs (§2.1-§2.4), et le produit est un seul code Flutter pour les deux.
class AppTheme {
  const AppTheme._();

  static ThemeData mobile({required bool dark}) => _build(
        colors: dark ? AmpereColors.mobileDark : AmpereColors.mobileLight,
        dark: dark,
        cardRadius: AmpereGeometry.cardRadiusMobile,
        fieldRadius: AmpereGeometry.fieldRadiusMobile,
        fieldHeight: AmpereGeometry.fieldHeightMobile,
        bodyStyle: AmpereType.body,
      );

  static ThemeData desktop({required bool dark}) => _build(
        colors: dark ? AmpereColors.desktopDark : AmpereColors.desktopLight,
        dark: dark,
        cardRadius: AmpereGeometry.cardRadiusDesktop,
        fieldRadius: AmpereGeometry.fieldRadiusDesktop,
        fieldHeight: AmpereGeometry.fieldHeightDesktop,
        bodyStyle: AmpereType.bodyDesktop,
      );

  static ThemeData _build({
    required AmpereColors colors,
    required bool dark,
    required double cardRadius,
    required double fieldRadius,
    required double fieldHeight,
    required TextStyle bodyStyle,
  }) {
    final scheme = ColorScheme(
      brightness: dark ? Brightness.dark : Brightness.light,
      primary: colors.accent,
      onPrimary: colors.onAccent,
      secondary: colors.accentHi,
      onSecondary: colors.onAccent,
      surface: colors.surface,
      onSurface: colors.ink,
      error: colors.error,
      onError: colors.onAccent,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      fontFamily: AmpereType.family,
      scaffoldBackgroundColor: colors.bg,
      dividerColor: colors.line,
      extensions: [colors],

      // Aucune ombre sur ce qui ne flotte pas : la bordure suffit (§4).
      cardTheme: CardThemeData(
        color: colors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: BorderSide(color: colors.line, width: AmpereGeometry.borderWidth),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: colors.lineSoft,
        thickness: AmpereGeometry.borderWidth,
        space: AmpereGeometry.borderWidth,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surface2,
        constraints: BoxConstraints(minHeight: fieldHeight),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: _fieldBorder(fieldRadius, colors.line),
        enabledBorder: _fieldBorder(fieldRadius, colors.line),
        // Focus toujours visible (§12.10) — jamais d'`outline:none`.
        focusedBorder: _fieldBorder(fieldRadius, colors.accent, width: 1.5),
        errorBorder: _fieldBorder(fieldRadius, colors.error),
        focusedErrorBorder: _fieldBorder(fieldRadius, colors.error, width: 1.5),
        // Le message d'erreur est SOUS le champ, jamais en infobulle (§6).
        errorStyle: AmpereType.metaDesktop.copyWith(color: colors.error),
        labelStyle: bodyStyle.copyWith(color: colors.ink2),
        floatingLabelStyle: bodyStyle.copyWith(color: colors.accent),
        hintStyle: bodyStyle.copyWith(color: colors.ink3),
        helperStyle: AmpereType.meta.copyWith(color: colors.ink3),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.accent,
          foregroundColor: colors.onAccent,
          disabledBackgroundColor: colors.accent.withValues(alpha: 0.45),
          disabledForegroundColor: colors.onAccent.withValues(alpha: 0.45),
          minimumSize: Size(0, fieldHeight),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          textStyle: bodyStyle.copyWith(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(fieldRadius),
          ),
        ).copyWith(side: focusSide(colors)),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.ink,
          backgroundColor: colors.surface2,
          minimumSize: Size(0, fieldHeight),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          textStyle: bodyStyle.copyWith(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(fieldRadius),
          ),
        ).copyWith(
          side: focusSide(
            colors,
            idle: BorderSide(
              color: colors.line,
              width: AmpereGeometry.borderWidth,
            ),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.accentHi,
          minimumSize: const Size(0, AmpereGeometry.touchMin),
          textStyle: bodyStyle.copyWith(fontWeight: FontWeight.w600),
        ).copyWith(side: focusSide(colors)),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(side: focusSide(colors)),
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: colors.bg,
        foregroundColor: colors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: AmpereType.screenTitle.copyWith(
          color: colors.ink,
          fontFamily: AmpereType.family,
        ),
      ),

      // Élévation 2 pour ce qui flotte réellement (§4).
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 24,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
        titleTextStyle: AmpereType.h3.copyWith(
          color: colors.ink,
          fontFamily: AmpereType.family,
        ),
        contentTextStyle: bodyStyle.copyWith(color: colors.ink2),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AmpereGeometry.sheetRadius),
          ),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surface,
        contentTextStyle: bodyStyle.copyWith(color: colors.ink),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.accentBg,
        height: AmpereGeometry.listRowMin,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => AmpereType.label.copyWith(
            fontFamily: AmpereType.family,
            color: states.contains(WidgetState.selected)
                ? colors.accentHi
                : colors.ink3,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 21,
            color: states.contains(WidgetState.selected)
                ? colors.accentHi
                : colors.ink3,
          ),
        ),
      ),

      iconTheme: IconThemeData(color: colors.ink2, size: 19),
      textTheme: _textTheme(colors, bodyStyle),
      textSelectionTheme: TextSelectionThemeData(cursorColor: colors.accent),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.accent,
        linearTrackColor: colors.surface3,
      ),
    );
  }

  /// Focus clavier TOUJOURS visible (§6, §12.10) : contour 2 px `accent`,
  /// tracé à l'EXTÉRIEUR du bouton (équivalent de `outline-offset`) pour rester
  /// visible sur un bouton déjà rempli d'accent. `idle` = bordure hors focus.
  static WidgetStateProperty<BorderSide?> focusSide(
    AmpereColors colors, {
    BorderSide? idle,
  }) =>
      WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(
                color: colors.accent,
                width: 2,
                strokeAlign: BorderSide.strokeAlignOutside,
              )
            : idle,
      );

  static OutlineInputBorder _fieldBorder(
    double radius,
    Color color, {
    double width = AmpereGeometry.borderWidth,
  }) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: BorderSide(color: color, width: width),
      );

  static TextTheme _textTheme(AmpereColors colors, TextStyle bodyStyle) {
    return TextTheme(
      headlineLarge: AmpereType.h1.copyWith(color: colors.ink),
      headlineMedium: AmpereType.screenTitle.copyWith(color: colors.ink),
      titleLarge: AmpereType.sectionTitle.copyWith(color: colors.ink),
      titleMedium: AmpereType.h4.copyWith(color: colors.ink),
      titleSmall: AmpereType.rowTitle.copyWith(color: colors.ink),
      bodyLarge: bodyStyle.copyWith(color: colors.ink),
      bodyMedium: bodyStyle.copyWith(color: colors.ink),
      bodySmall: AmpereType.meta.copyWith(color: colors.ink2),
      labelLarge: bodyStyle.copyWith(
        color: colors.ink,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: AmpereType.meta.copyWith(color: colors.ink3),
      labelSmall: AmpereType.label.copyWith(color: colors.ink3),
    );
  }
}
