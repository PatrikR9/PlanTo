/// Small Czech-specific formatters shared by more than one screen.
///
/// These are not localisation — `intl` does dates and plurals. They exist for
/// the handful of shapes ICU has no pattern for, and they live here so the
/// same "1,5 h" does not get written three slightly different ways.
library;

/// `7:00`, `18:30`. Czech uses no leading zero on the hour.
///
/// Takes a [Duration] since midnight rather than a `DateTime` because a
/// wall-clock time is not a moment — it is "seven o'clock", on any day.
String formatWallClock(Duration d) =>
    '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}';

/// `30 min`, `1 h`, `1,5 h`. Decimal comma, and never "1.0 h".
String formatLength(int minutes) {
  if (minutes < 60) return '$minutes min';
  if (minutes % 60 == 0) return '${minutes ~/ 60} h';
  return '${(minutes / 60).toStringAsFixed(1).replaceAll('.', ',')} h';
}

/// Czech weekday and month names come out of intl lowercase, which reads as a
/// typo at the start of a line.
String capitalise(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
