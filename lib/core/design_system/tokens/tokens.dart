/// Design tokens — the single source of truth for spacing, shape and motion.
///
/// Rule (architecture section 7.2): no feature code may hard-code a colour,
/// size, radius or duration. Everything comes from here or from the theme.
library;

import 'package:flutter/widgets.dart';

/// Spacing scale. 4-point grid, named by t-shirt size.
abstract final class Sp {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;
  static const double huge = 56;
  static const double giant = 72;
}

/// Corner radii.
abstract final class Radii {
  static const Radius chip = Radius.circular(8);
  static const Radius input = Radius.circular(12);
  static const Radius card = Radius.circular(16);
  static const Radius sheet = Radius.circular(24);
  static const Radius pill = Radius.circular(999);

  static const BorderRadius chipAll = BorderRadius.all(chip);
  static const BorderRadius inputAll = BorderRadius.all(input);
  static const BorderRadius cardAll = BorderRadius.all(card);
  static const BorderRadius pillAll = BorderRadius.all(pill);
  static const BorderRadius sheetTop =
      BorderRadius.vertical(top: sheet);
}

/// Motion. Three durations, no more.
abstract final class Motion {
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 220);
  static const Duration emphasised = Duration(milliseconds: 380);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve emphasis = Cubic(0.05, 0.7, 0.1, 1); // M3 emphasised-decelerate
}

/// Breakpoints (architecture section 7.5).
abstract final class Breakpoints {
  static const double compact = 600;
  static const double medium = 840;

  static bool isCompact(double width) => width < compact;
  static bool isExpanded(double width) => width >= medium;
}
