import 'package:flutter/material.dart';

/// Semantic colours that Material 3's ColorScheme has no slot for.
///
/// Accessed via `Theme.of(context).extension<PlanToTheme>()!` or the
/// `context.planto` extension in app_theme.dart.
@immutable
class PlanToTheme extends ThemeExtension<PlanToTheme> {
  const PlanToTheme({
    required this.weatherGood,
    required this.weatherFair,
    required this.weatherPoor,
    required this.weatherSevere,
    required this.availabilityFull,
    required this.availabilityPartial,
    required this.availabilityNone,
    required this.costLow,
    required this.costMid,
    required this.costHigh,
    required this.hairline,
  });

  final Color weatherGood;
  final Color weatherFair;
  final Color weatherPoor;
  final Color weatherSevere;

  final Color availabilityFull;
  final Color availabilityPartial;
  final Color availabilityNone;

  final Color costLow;
  final Color costMid;
  final Color costHigh;

  /// 1px separator colour. Depth comes from hairlines and tinted surfaces,
  /// not from heavy shadows (architecture section 7.1).
  final Color hairline;

  /// Maps a 0-100 weather score to its band colour.
  /// Colour is never the only signal — see PtWeatherGlyph for the paired icon.
  Color weatherForScore(int score) {
    if (score >= 80) return weatherGood;
    if (score >= 60) return weatherGood;
    if (score >= 40) return weatherFair;
    if (score >= 20) return weatherPoor;
    return weatherSevere;
  }

  static const PlanToTheme light = PlanToTheme(
    weatherGood: Color(0xFF15803D),
    weatherFair: Color(0xFFB45309),
    weatherPoor: Color(0xFFC2410C),
    weatherSevere: Color(0xFFB91C1C),
    availabilityFull: Color(0xFF0F766E),
    availabilityPartial: Color(0xFF5EAAA8),
    availabilityNone: Color(0xFFD4D4D8),
    costLow: Color(0xFF15803D),
    costMid: Color(0xFFB45309),
    costHigh: Color(0xFFB91C1C),
    hairline: Color(0x1A000000),
  );

  static const PlanToTheme dark = PlanToTheme(
    weatherGood: Color(0xFF4ADE80),
    weatherFair: Color(0xFFFBBF24),
    weatherPoor: Color(0xFFFB923C),
    weatherSevere: Color(0xFFF87171),
    availabilityFull: Color(0xFF2DD4BF),
    availabilityPartial: Color(0xFF14807A),
    availabilityNone: Color(0xFF3F3F46),
    costLow: Color(0xFF4ADE80),
    costMid: Color(0xFFFBBF24),
    costHigh: Color(0xFFF87171),
    hairline: Color(0x1FFFFFFF),
  );

  @override
  PlanToTheme copyWith({
    Color? weatherGood,
    Color? weatherFair,
    Color? weatherPoor,
    Color? weatherSevere,
    Color? availabilityFull,
    Color? availabilityPartial,
    Color? availabilityNone,
    Color? costLow,
    Color? costMid,
    Color? costHigh,
    Color? hairline,
  }) {
    return PlanToTheme(
      weatherGood: weatherGood ?? this.weatherGood,
      weatherFair: weatherFair ?? this.weatherFair,
      weatherPoor: weatherPoor ?? this.weatherPoor,
      weatherSevere: weatherSevere ?? this.weatherSevere,
      availabilityFull: availabilityFull ?? this.availabilityFull,
      availabilityPartial: availabilityPartial ?? this.availabilityPartial,
      availabilityNone: availabilityNone ?? this.availabilityNone,
      costLow: costLow ?? this.costLow,
      costMid: costMid ?? this.costMid,
      costHigh: costHigh ?? this.costHigh,
      hairline: hairline ?? this.hairline,
    );
  }

  @override
  PlanToTheme lerp(ThemeExtension<PlanToTheme>? other, double t) {
    if (other is! PlanToTheme) return this;
    return PlanToTheme(
      weatherGood: Color.lerp(weatherGood, other.weatherGood, t)!,
      weatherFair: Color.lerp(weatherFair, other.weatherFair, t)!,
      weatherPoor: Color.lerp(weatherPoor, other.weatherPoor, t)!,
      weatherSevere: Color.lerp(weatherSevere, other.weatherSevere, t)!,
      availabilityFull:
          Color.lerp(availabilityFull, other.availabilityFull, t)!,
      availabilityPartial:
          Color.lerp(availabilityPartial, other.availabilityPartial, t)!,
      availabilityNone:
          Color.lerp(availabilityNone, other.availabilityNone, t)!,
      costLow: Color.lerp(costLow, other.costLow, t)!,
      costMid: Color.lerp(costMid, other.costMid, t)!,
      costHigh: Color.lerp(costHigh, other.costHigh, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
    );
  }
}
