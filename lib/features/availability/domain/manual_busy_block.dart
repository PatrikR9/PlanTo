import 'package:flutter/foundation.dart';

/// One thing the user typed in by hand: a whole day, or a part of one.
///
/// Modelled as a local date plus optional wall-clock times rather than two
/// instants, because that is what the person means. Turning it into an actual
/// interval needs the *trip's* timezone, which the client does not have — so
/// that conversion happens in `set_manual_busy`, server-side.
@immutable
class ManualBusyBlock {
  const ManualBusyBlock({required this.day, this.from, this.to});

  const ManualBusyBlock.allDay(this.day)
      : from = null,
        to = null;

  /// Local midnight of the day this block belongs to.
  final DateTime day;

  /// Wall-clock start and end. Both null means the whole day.
  final Duration? from;
  final Duration? to;

  bool get isAllDay => from == null;

  ManualBusyBlock copyWith({Duration? from, Duration? to}) =>
      ManualBusyBlock(day: day, from: from ?? this.from, to: to ?? this.to);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'day': _isoDate(day),
        if (from != null) 'from': _hhmm(from!),
        if (to != null) 'to': _hhmm(to!),
      };

  static ManualBusyBlock fromRow(Map<String, dynamic> r) {
    final DateTime day = DateTime.parse(r['day'] as String);
    if (r['is_all_day'] as bool? ?? false) {
      return ManualBusyBlock.allDay(day);
    }
    return ManualBusyBlock(
      day: day,
      from: _parseTime(r['from_time'] as String?),
      to: _parseTime(r['to_time'] as String?),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ManualBusyBlock &&
      other.day == day &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(day, from, to);
}

String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _hhmm(Duration d) => '${d.inHours.toString().padLeft(2, '0')}:'
    '${(d.inMinutes % 60).toString().padLeft(2, '0')}';

Duration? _parseTime(String? v) {
  if (v == null) return null;
  final List<String> parts = v.split(':');
  if (parts.length < 2) return null;
  return Duration(
    hours: int.tryParse(parts[0]) ?? 0,
    minutes: int.tryParse(parts[1]) ?? 0,
  );
}
