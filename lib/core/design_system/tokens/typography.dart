import 'package:flutter/material.dart';

/// Type scale from architecture section 7.1.
///
/// Inter is bundled rather than fetched at runtime: it works offline, avoids a
/// network call on first paint, and has complete Czech diacritics.
/// Flip to true once the four Inter .ttf files are in assets/fonts/ and the
/// `fonts:` block in pubspec.yaml is uncommented. Until then the platform
/// default is used so a fresh clone builds with no downloads.
const bool kUseBundledInter = false;

abstract final class AppTypography {
  static const String? fontFamily = kUseBundledInter ? 'Inter' : null;

  static const TextTheme textTheme = TextTheme(
    displaySmall: TextStyle(
      fontSize: 34, height: 40 / 34, fontWeight: FontWeight.w700, letterSpacing: -0.5,
    ),
    titleLarge: TextStyle(
      fontSize: 24, height: 30 / 24, fontWeight: FontWeight.w600, letterSpacing: -0.3,
    ),
    headlineSmall: TextStyle(
      fontSize: 20, height: 26 / 20, fontWeight: FontWeight.w600,
    ),
    bodyLarge: TextStyle(
      fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w400,
    ),
    bodyMedium: TextStyle(
      fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w400,
    ),
    labelLarge: TextStyle(
      fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w600,
    ),
    labelSmall: TextStyle(
      fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500,
    ),
  );
}
