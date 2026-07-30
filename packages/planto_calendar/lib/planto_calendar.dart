import 'package:flutter/services.dart';

/// A calendar the user has on their device.
class DeviceCalendar {
  const DeviceCalendar({
    required this.id,
    required this.name,
    required this.accountName,
    required this.isPrimary,
  });

  final String id;
  final String name;
  final String accountName;
  final bool isPrimary;
}

/// A block of time the user is busy. There is no title, no location and no
/// guest list — the native layer never reads those columns.
class DeviceBusyBlock {
  const DeviceBusyBlock({
    required this.startMs,
    required this.endMs,
    required this.isAllDay,
  });

  final int startMs;
  final int endMs;
  final bool isAllDay;

  DateTime get start => DateTime.fromMillisecondsSinceEpoch(startMs);
  DateTime get end => DateTime.fromMillisecondsSinceEpoch(endMs);
}

class CalendarPermissionDenied implements Exception {
  const CalendarPermissionDenied({required this.permanently});

  /// True when the user checked "don't ask again". Only Settings can fix it,
  /// so the UI must offer that instead of asking a second time.
  final bool permanently;
}

/// Reads busy times from the device's calendar store.
///
/// Deliberately narrow. The whole privacy promise of the product — "we never
/// read your event titles" — is enforced here, in the platform code, by the
/// column projection. A general-purpose calendar plugin would hand Dart the
/// full event objects and leave that promise to discipline.
class PlantoCalendar {
  const PlantoCalendar();

  static const MethodChannel _channel = MethodChannel('app.planto/calendar');

  Future<bool> hasPermission() async =>
      await _channel.invokeMethod<bool>('hasPermission') ?? false;

  /// Returns true if granted. Throws [CalendarPermissionDenied] when refused.
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        throw CalendarPermissionDenied(
          permanently: e.details == 'permanently',
        );
      }
      rethrow;
    }
  }

  Future<List<DeviceCalendar>> calendars() async {
    final List<dynamic> raw =
        await _channel.invokeMethod<List<dynamic>>('calendars') ??
            <dynamic>[];
    return raw
        .cast<Map<dynamic, dynamic>>()
        .map(
          (Map<dynamic, dynamic> m) => DeviceCalendar(
            id: m['id'] as String,
            name: (m['name'] as String?) ?? 'Kalendář',
            accountName: (m['account'] as String?) ?? '',
            isPrimary: (m['primary'] as bool?) ?? false,
          ),
        )
        .toList();
  }

  /// Busy blocks between [from] and [to] for the given calendars.
  ///
  /// Instances are expanded natively, so recurring events, exceptions and
  /// moved occurrences are already resolved — getting that right in Dart is a
  /// well-known source of subtle bugs.
  Future<List<DeviceBusyBlock>> busyBlocks({
    required DateTime from,
    required DateTime to,
    required List<String> calendarIds,
  }) async {
    final List<dynamic> raw = await _channel.invokeMethod<List<dynamic>>(
          'busyBlocks',
          <String, dynamic>{
            'from': from.millisecondsSinceEpoch,
            'to': to.millisecondsSinceEpoch,
            'calendarIds': calendarIds,
          },
        ) ??
        <dynamic>[];

    return raw
        .cast<Map<dynamic, dynamic>>()
        .map(
          (Map<dynamic, dynamic> m) => DeviceBusyBlock(
            startMs: (m['start'] as num).toInt(),
            endMs: (m['end'] as num).toInt(),
            isAllDay: (m['allDay'] as bool?) ?? false,
          ),
        )
        .toList();
  }
}
