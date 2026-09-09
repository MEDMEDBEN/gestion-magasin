import 'package:flutter/material.dart';

/// Direction artistique : 80 % logiciel professionnel, 20 % identité électrique
/// (docs/spec-fonctionnelle.md §30). Thème sombre bleu nuit, accent cyan.
/// Très peu de glow : on évite l'interface « gaming ».
class AppColors {
  const AppColors._();

  /// Fond général — bleu/noir très sombre.
  static const background = Color(0xFF0B1017);

  /// Surfaces (cartes, panneaux) — légèrement plus claires que le fond.
  static const surface = Color(0xFF131C26);
  static const surfaceElevated = Color(0xFF1B2733);

  /// Accent cyan / bleu électrique.
  static const accent = Color(0xFF22D3EE);
  static const accentMuted = Color(0xFF0E7490);

  static const success = Color(0xFF34D399);
  static const warning = Color(0xFFFBBF24);
  static const danger = Color(0xFFF87171);

  static const textPrimary = Color(0xFFE6EDF3);
  static const textSecondary = Color(0xFF8B9AAB);
  static const border = Color(0xFF243447);
}

class AppTheme {
  const AppTheme._();

  /// Coins arrondis modérés, bordures fines — pas d'effet de profondeur marqué.
  static const double radius = 10;

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: AppColors.accent,
      onPrimary: Color(0xFF04212B),
      secondary: AppColors.accentMuted,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      error: AppColors.danger,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      dividerColor: AppColors.border,
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceElevated,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48), // cible tactile confortable sur mobile
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: AppColors.textPrimary),
        bodySmall: TextStyle(color: AppColors.textSecondary),
      ),
    );
  }
}
