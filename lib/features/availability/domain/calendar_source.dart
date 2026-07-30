import 'busy_interval.dart';

class CalendarInfo {
  const CalendarInfo({
    required this.id,
    required this.name,
    required this.account,
    required this.isPrimary,
  });

  final String id;
  final String name;
  final String account;
  final bool isPrimary;

  /// Birthday and holiday feeds are noise for trip planning and would mark
  /// every participant busy on the same irrelevant days, so they start off.
  bool get suggestedByDefault {
    final String n = name.toLowerCase();
    const List<String> noisy = <String>[
      'birthday', 'narozenin', 'holiday', 'svátk', 'svatk', 'contacts',
    ];
    return !noisy.any(n.contains);
  }
}

/// Where busy times come from. Abstracted because Android is the only platform
/// that has an implementation right now: web has no calendar API at all, and
/// iOS arrives with EventKit in V2. Without this seam the availability UI
/// could not be built or reviewed anywhere but on a phone.
abstract interface class CalendarSource {
  bool get isSupported;
  Future<bool> hasPermission();
  Future<bool> requestPermission();
  Future<List<CalendarInfo>> calendars();
  Future<List<BusyInterval>> busyBlocks({
    required DateTime from,
    required DateTime to,
    required List<String> calendarIds,
  });
}
