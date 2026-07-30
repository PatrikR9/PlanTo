import 'package:flutter/foundation.dart';

/// A block of time somebody is not available. No title, no location, no
/// guests — the schema has nowhere to put them and the platform channel never
/// reads them.
@immutable
class BusyInterval {
  const BusyInterval({
    required this.start,
    required this.end,
    this.isAllDay = false,
  });

  final DateTime start;
  final DateTime end;
  final bool isAllDay;

  Duration get duration => end.difference(start);

  BusyInterval copyWith({DateTime? start, DateTime? end, bool? isAllDay}) =>
      BusyInterval(
        start: start ?? this.start,
        end: end ?? this.end,
        isAllDay: isAllDay ?? this.isAllDay,
      );

  @override
  bool operator ==(Object other) =>
      other is BusyInterval &&
      other.start == start &&
      other.end == end &&
      other.isAllDay == isAllDay;

  @override
  int get hashCode => Object.hash(start, end, isAllDay);

  @override
  String toString() =>
      'Busy(${start.toIso8601String()} → ${end.toIso8601String()})';
}

/// Turns raw device events into the minimum set of intervals worth uploading.
///
/// Runs on the device, before anything leaves it. Three jobs:
///   1. clip to the trip window, so a year of calendar history never travels;
///   2. round outward to 15 minutes, which coarsens the data (a meeting at
///      14:03 becomes 14:00) and costs nothing in accuracy for planning a day
///      trip — a deliberate privacy/precision trade;
///   3. merge overlaps, which usually collapses a busy work week into a
///      handful of rows.
abstract final class BusyIntervals {
  static const Duration granularity = Duration(minutes: 15);

  static List<BusyInterval> prepare(
    List<BusyInterval> raw, {
    required DateTime windowStart,
    required DateTime windowEnd,
  }) {
    final List<BusyInterval> clipped = <BusyInterval>[];

    for (final BusyInterval i in raw) {
      final DateTime s = i.start.isBefore(windowStart) ? windowStart : i.start;
      final DateTime e = i.end.isAfter(windowEnd) ? windowEnd : i.end;
      if (!e.isAfter(s)) continue; // entirely outside the window
      clipped.add(BusyInterval(start: s, end: e, isAllDay: i.isAllDay));
    }

    final List<BusyInterval> rounded = clipped
        .map(
          (BusyInterval i) => i.copyWith(
            start: _floor(i.start),
            end: _ceil(i.end),
          ),
        )
        .toList()
      ..sort((BusyInterval a, BusyInterval b) => a.start.compareTo(b.start));

    return _merge(rounded);
  }

  /// Merges overlapping and touching intervals. Touching counts: 09:00–10:00
  /// followed by 10:00–11:00 is two hours of being unavailable, and storing it
  /// as one row is both smaller and truer to how a person experiences it.
  static List<BusyInterval> _merge(List<BusyInterval> sorted) {
    final List<BusyInterval> out = <BusyInterval>[];
    for (final BusyInterval i in sorted) {
      if (out.isEmpty || i.start.isAfter(out.last.end)) {
        out.add(i);
        continue;
      }
      final BusyInterval last = out.removeLast();
      out.add(
        BusyInterval(
          start: last.start,
          end: i.end.isAfter(last.end) ? i.end : last.end,
          isAllDay: last.isAllDay && i.isAllDay,
        ),
      );
    }
    return out;
  }

  static DateTime _floor(DateTime t) {
    final int m = t.minute - (t.minute % granularity.inMinutes);
    return DateTime(t.year, t.month, t.day, t.hour, m);
  }

  static DateTime _ceil(DateTime t) {
    if (t.minute % granularity.inMinutes == 0 &&
        t.second == 0 &&
        t.millisecond == 0) {
      return DateTime(t.year, t.month, t.day, t.hour, t.minute);
    }
    final int m = t.minute - (t.minute % granularity.inMinutes);
    return DateTime(t.year, t.month, t.day, t.hour, m).add(granularity);
  }
}
