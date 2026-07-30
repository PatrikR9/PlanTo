import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

/// Three states, not two.
///
/// "Maybe" is the honest answer to most proposed dates, and a poll that
/// forces it into yes/no collects a number nobody believes. It also gives the
/// organiser something actionable: a slot with four maybes is worth nudging,
/// one with four noes is not.
enum DateVote {
  yes('yes'),
  maybe('maybe'),
  no('no');

  const DateVote(this.wire);

  /// The value the database enum uses. Kept explicit so renaming the Dart
  /// constant cannot silently break the RPC.
  final String wire;

  static DateVote? fromWire(String? v) =>
      DateVote.values.where((DateVote e) => e.wire == v).firstOrNull;
}

/// One proposed *termín* — a whole day (or block of days) in day mode, a
/// time slot in time mode. "Date" here means the thing you agree on, not a
/// calendar date; the solver returns the same shape either way.
///
/// Score and votes are deliberately separate numbers. The score is what the
/// deterministic engine computed from availability, weekend and holiday; the
/// votes are what people said. Blending them would hide which is which, and
/// the whole product claim is that the machine's reasoning is inspectable.
@immutable
class DateCandidate {
  const DateCandidate({
    required this.startsAt,
    required this.endsAt,
    required this.windowEndsAt,
    required this.freeCount,
    required this.totalCount,
    required this.freeUserIds,
    required this.busyUserIds,
    required this.isWeekend,
    required this.isHoliday,
    required this.score,
    required this.yesCount,
    required this.maybeCount,
    required this.noCount,
    required this.isLocked,
    this.myVote,
    this.weatherScore,
    this.weatherCode,
    this.tempMax,
    this.precipProb,
    this.windGustKmh,
    this.sunrise,
    this.sunset,
  });

  final DateTime startsAt;

  /// When the activity itself would finish. Exclusive.
  final DateTime endsAt;

  /// End of the contiguous free window this candidate sits in. Equal to
  /// [endsAt] in day mode. In time mode it is how much room there actually
  /// is, which is what tells a group they could start later if they wanted.
  final DateTime windowEndsAt;

  final int freeCount;
  final int totalCount;
  final List<String> freeUserIds;
  final List<String> busyUserIds;
  final bool isWeekend;
  final bool isHoliday;

  /// 0.0–0.70 today. Weather (0.20) and daylight (0.10) land in M6, which is
  /// why this is not presented to the user as a percentage of 100.
  final double score;

  final int yesCount;
  final int maybeCount;
  final int noCount;
  final DateVote? myVote;
  final bool isLocked;

  /// 0–100, or null past the forecast horizon.
  ///
  /// Null means *unknown*, never *bad*. The ranking renormalises its weights
  /// rather than treating a missing forecast as a zero, and the UI has to
  /// make the same distinction — "předpověď zatím není" is information, "0/100"
  /// is a lie.
  final int? weatherScore;

  /// WMO code, for the glyph. See [weatherIsStormy].
  final int? weatherCode;
  final double? tempMax;
  final int? precipProb;
  final double? windGustKmh;
  final DateTime? sunrise;
  final DateTime? sunset;

  bool get hasWeather => weatherScore != null;

  /// WMO 95/96/99. Worth its own flag because a thunderstorm is a safety
  /// matter above a ridge, not a comfort one.
  bool get weatherIsStormy => const <int>{95, 96, 99}.contains(weatherCode);

  /// True when the activity would run past sunset. User story D4: "will we be
  /// descending in the dark".
  bool get endsAfterDark {
    final DateTime? s = sunset;
    return s != null && endsAt.isAfter(s);
  }

  /// The calendar day this candidate starts on. Used to group the list, so it
  /// must be a plain local date with no time component.
  DateTime get day => DateTime(startsAt.year, startsAt.month, startsAt.day);

  bool get everyoneFree => totalCount > 0 && freeCount == totalCount;

  /// True when the free window is longer than the activity, i.e. the group
  /// has room to start later. Only ever true in time mode.
  bool get hasSlack => windowEndsAt.isAfter(endsAt);

  /// Share of the group that is free. This is the number the ring shows —
  /// it is the one thing on the card a person can verify for themselves.
  int get availabilityPercent =>
      totalCount == 0 ? 0 : ((freeCount / totalCount) * 100).round();

  int get votesCast => yesCount + maybeCount + noCount;
}
