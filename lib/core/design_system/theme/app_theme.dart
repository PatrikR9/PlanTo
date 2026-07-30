import 'package:flutter/material.dart';

import '../tokens/tokens.dart';
import '../tokens/typography.dart';
import 'planto_theme.dart';

/// Brand seed colour. Deep teal — outdoors without being literal about it.
/// Placeholder until brand work is done; changing it re-derives both themes.
const Color kBrandSeed = Color(0xFF0F766E);

abstract final class AppTheme {
  /// [dynamicScheme] carries Material You colours from the user's wallpaper on
  /// Android 12+. Passing null falls back to the brand palette.
  static ThemeData light([ColorScheme? dynamicScheme]) => _build(
        dynamicScheme ??
            ColorScheme.fromSeed(
              seedColor: kBrandSeed,
            ),
        PlanToTheme.light,
      );

  static ThemeData dark([ColorScheme? dynamicScheme]) => _build(
        dynamicScheme ??
            ColorScheme.fromSeed(
              seedColor: kBrandSeed,
              brightness: Brightness.dark,
            ).copyWith(
              surface: const Color(0xFF0B0D10),
              surfaceContainer: const Color(0xFF14181D),
            ),
        PlanToTheme.dark,
      );

  static ThemeData _build(ColorScheme scheme, PlanToTheme ext) {
    final TextTheme text = AppTypography.textTheme.apply(
      fontFamily: AppTypography.fontFamily,
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: text,
      scaffoldBackgroundColor: scheme.surface,
      extensions: <ThemeExtension<dynamic>>[ext],

      // Card styling lives in PtCard, not here: the CardTheme/CardThemeData
      // type changed across Flutter versions and pinning the theme to one of
      // them makes the project fragile across SDK upgrades.
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        shape: RoundedRectangleBorder(borderRadius: Radii.sheetTop),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: const OutlineInputBorder(
          borderRadius: Radii.inputAll,
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Sp.md,
          vertical: Sp.sm,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // 48dp minimum touch target (architecture section 7.6).
          minimumSize: const Size(64, 48),
          shape: const RoundedRectangleBorder(borderRadius: Radii.inputAll),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      chipTheme: ChipThemeData(
        shape: const RoundedRectangleBorder(borderRadius: Radii.chipAll),
        side: BorderSide(color: ext.hairline),
      ),
      dividerTheme:
          DividerThemeData(color: ext.hairline, space: 1, thickness: 1),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        backgroundColor: scheme.surface,
        indicatorShape:
            const RoundedRectangleBorder(borderRadius: Radii.pillAll),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// Convenience accessor so feature code reads
/// `context.planto.weatherGood` instead of the full extension lookup.
extension PlanToThemeX on BuildContext {
  PlanToTheme get planto => Theme.of(this).extension<PlanToTheme>()!;
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get texts => Theme.of(this).textTheme;
}
