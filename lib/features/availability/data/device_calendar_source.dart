import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:planto_calendar/planto_calendar.dart';

import '../../../core/error/failure.dart';
import '../domain/busy_interval.dart';
import '../domain/calendar_source.dart';

class AndroidCalendarSource implements CalendarSource {
  const AndroidCalendarSource();

  static const PlantoCalendar _plugin = PlantoCalendar();

  @override
  bool get isSupported => true;

  @override
  Future<bool> hasPermission() => _plugin.hasPermission();

  @override
  Future<bool> requestPermission() async {
    try {
      return await _plugin.requestPermission();
    } on CalendarPermissionDenied catch (e) {
      throw PermissionFailure(
        permission: e.permanently ? 'calendar_permanent' : 'calendar',
        cause: e,
      );
    }
  }

  @override
  Future<List<CalendarInfo>> calendars() async {
    final List<DeviceCalendar> raw = await _plugin.calendars();
    return raw
        .map(
          (DeviceCalendar c) => CalendarInfo(
            id: c.id,
            name: c.name,
            account: c.accountName,
            isPrimary: c.isPrimary,
          ),
        )
        .toList();
  }

  @override
  Future<List<BusyInterval>> busyBlocks({
    required DateTime from,
    required DateTime to,
    required List<String> calendarIds,
  }) async {
    final List<DeviceBusyBlock> raw = await _plugin.busyBlocks(
      from: from,
      to: to,
      calendarIds: calendarIds,
    );
    return raw
        .map(
          (DeviceBusyBlock b) => BusyInterval(
            start: b.start,
            end: b.end,
            isAllDay: b.isAllDay,
          ),
        )
        .toList();
  }
}

/// Web and iOS-until-V2. Reports itself unsupported so the UI can offer the
/// manual grid instead of a button that cannot work.
class UnsupportedCalendarSource implements CalendarSource {
  const UnsupportedCalendarSource();

  @override
  bool get isSupported => false;
  @override
  Future<bool> hasPermission() async => false;
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<List<CalendarInfo>> calendars() async => <CalendarInfo>[];
  @override
  Future<List<BusyInterval>> busyBlocks({
    required DateTime from,
    required DateTime to,
    required List<String> calendarIds,
  }) async =>
      <BusyInterval>[];
}

final Provider<CalendarSource> calendarSourceProvider =
    Provider<CalendarSource>((Ref ref) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return const AndroidCalendarSource();
  }
  return const UnsupportedCalendarSource();
});
