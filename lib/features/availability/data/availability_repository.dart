import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
import '../../../core/error/failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/busy_interval.dart';
import '../domain/calendar_feed.dart';
import '../domain/manual_busy_block.dart';

/// One day of group availability, as computed by group_free_days().
class DayAvailability {
  const DayAvailability({
    required this.day,
    required this.freeCount,
    required this.totalCount,
    required this.freeUserIds,
    required this.busyUserIds,
    required this.isWeekend,
    required this.isHoliday,
  });

  final DateTime day;
  final int freeCount;
  final int totalCount;
  final List<String> freeUserIds;
  final List<String> busyUserIds;
  final bool isWeekend;
  final bool isHoliday;

  bool get everyoneFree => totalCount > 0 && freeCount == totalCount;
  double get ratio => totalCount == 0 ? 0 : freeCount / totalCount;
}

abstract interface class AvailabilityRepository {
  /// Replaces this user's intervals for the trip. Replace rather than append:
  /// a re-sync after the user deletes a meeting must remove it here too.
  Future<void> uploadMine(String tripId, List<BusyInterval> intervals);
  Future<List<DayAvailability>> forTrip(String tripId);

  /// Deletes them again, and un-marks the user as having shared. There is no
  /// separate `markShared`: every write path sets the flag inside the same
  /// transaction as the rows, because the two disagreeing is what makes a
  /// group wait for somebody who is already done.
  Future<void> deleteMine(String tripId);

  /// Manual fallback: whole days or parts of days this user cannot make.
  ///
  /// No timezone conversion on the client — the RPC interprets each date and
  /// wall-clock time in the *trip's* timezone, which is the only correct
  /// reading and the only one a travelling user gets right. Passing an empty
  /// list is meaningful ("nothing blocks me") and still marks them as having
  /// shared.
  Future<void> setManualBlocks(String tripId, List<ManualBusyBlock> blocks);

  /// What this user previously entered, so reopening the editor is not a
  /// blank slate. Read through an RPC because SELECT on busy_intervals is
  /// revoked from every role — even for your own rows.
  Future<List<ManualBusyBlock>> myBlocks(String tripId);

  /// The iCal links this user has subscribed, minus the links themselves.
  Future<List<CalendarFeed>> myFeeds();

  /// Adds [url] if given, then re-syncs every saved feed into this trip.
  ///
  /// The URL goes straight to the Edge Function and is never stored on the
  /// device: it is a credential, and the fewer places it exists the better.
  Future<void> syncFeeds(String tripId, {String? url, String? label});

  Future<void> deleteFeed(String feedId);
}

class SupabaseAvailabilityRepository implements AvailabilityRepository {
  const SupabaseAvailabilityRepository(this._client);

  final SupabaseClient _client;

  /// Through an RPC, not PostgREST, because SELECT on `busy_intervals` is
  /// revoked from every role — deliberately, so a future bug in a read policy
  /// cannot leak somebody's schedule. That makes the table untouchable from
  /// the client in *both* directions: Postgres wants SELECT on every column a
  /// DELETE reads in its WHERE, so "replace my blocks" failed on 42501 before
  /// it ever got to the insert.
  ///
  /// Replacing them server-side is also one transaction rather than two round
  /// trips, and the window between them was one where a user could end up with
  /// no availability at all.
  ///
  /// An empty list is still sent: "nothing in my calendar blocks this trip" is
  /// an answer, and it is the one that marks you as having shared.
  @override
  Future<void> uploadMine(String tripId, List<BusyInterval> intervals) =>
      guard(() async {
        await _client.rpc<void>(
          'set_device_busy',
          params: <String, dynamic>{
            'p_trip': tripId,
            'p_blocks': <Map<String, dynamic>>[
              for (final BusyInterval i in intervals)
                <String, dynamic>{
                  'start': i.start.toUtc().toIso8601String(),
                  'end': i.end.toUtc().toIso8601String(),
                  'all_day': i.isAllDay,
                },
            ],
          },
        );
      });

  @override
  Future<List<DayAvailability>> forTrip(String tripId) => guard(() async {
        final List<dynamic> rows = await _client.rpc<List<dynamic>>(
          'group_free_days',
          params: <String, dynamic>{'p_trip': tripId},
        );

        return rows.cast<Map<String, dynamic>>().map((Map<String, dynamic> r) {
          return DayAvailability(
            day: DateTime.parse(r['day'] as String),
            freeCount: (r['free_count'] as int?) ?? 0,
            totalCount: (r['total_count'] as int?) ?? 0,
            freeUserIds:
                (r['free_user_ids'] as List<dynamic>? ?? const <dynamic>[])
                    .cast<String>(),
            busyUserIds:
                (r['busy_user_ids'] as List<dynamic>? ?? const <dynamic>[])
                    .cast<String>(),
            isWeekend: (r['is_weekend'] as bool?) ?? false,
            isHoliday: (r['is_holiday'] as bool?) ?? false,
          );
        }).toList()
          ..sort(
            (DayAvailability a, DayAvailability b) => a.day.compareTo(b.day),
          );
      });

  /// Same reason as [uploadMine], plus one of its own: clearing the rows and
  /// clearing the flag have to happen together, or the group sits waiting on
  /// availability that no longer exists.
  @override
  Future<void> deleteMine(String tripId) => guard(() async {
        await _client.rpc<void>(
          'clear_my_busy',
          params: <String, dynamic>{'p_trip': tripId},
        );
      });

  @override
  Future<void> setManualBlocks(String tripId, List<ManualBusyBlock> blocks) =>
      guard(() async {
        await _client.rpc<void>(
          'set_manual_busy',
          params: <String, dynamic>{
            'p_trip': tripId,
            'p_blocks': <Map<String, dynamic>>[
              for (final ManualBusyBlock b in blocks) b.toJson(),
            ],
          },
        );
      });

  @override
  Future<List<ManualBusyBlock>> myBlocks(String tripId) => guard(() async {
        final List<dynamic> rows = await _client.rpc<List<dynamic>>(
          'my_busy_blocks',
          params: <String, dynamic>{'p_trip': tripId},
        );
        return rows
            .cast<Map<String, dynamic>>()
            .map(ManualBusyBlock.fromRow)
            .toList();
      });

  @override
  Future<List<CalendarFeed>> myFeeds() => guard(() async {
        final List<dynamic> rows =
            await _client.rpc<List<dynamic>>('my_calendar_feeds');
        return rows
            .cast<Map<String, dynamic>>()
            .map(CalendarFeed.fromRow)
            .toList();
      });

  @override
  Future<void> syncFeeds(String tripId, {String? url, String? label}) => guard(
        timeout: kSlowRequestTimeout,
        () async {
          // invoke() throws FunctionException on a 4xx; error_mapper pulls the
          // function's own sentence out of it. "Kalendář odpověděl 404" and
          // "this feed was revoked" call for different reactions, so neither
          // gets flattened into "something went wrong".
          await _client.functions.invoke(
            'ical-sync',
            body: <String, dynamic>{
              'trip_id': tripId,
              if (url != null) 'url': url,
              if (label != null) 'label': label,
            },
          );
        },
      );

  @override
  Future<void> deleteFeed(String feedId) => guard(() async {
        await _client.rpc<void>(
          'delete_calendar_feed',
          params: <String, dynamic>{'p_feed': feedId},
        );
      });
}

class UnconfiguredAvailabilityRepository implements AvailabilityRepository {
  const UnconfiguredAvailabilityRepository();
  Never _fail() => throw const ServerFailure(code: 'NO_BACKEND');

  @override
  Future<void> uploadMine(String t, List<BusyInterval> i) async => _fail();
  @override
  Future<List<DayAvailability>> forTrip(String t) async => <DayAvailability>[];
  @override
  Future<void> deleteMine(String t) async {}
  @override
  Future<void> setManualBlocks(String t, List<ManualBusyBlock> b) async =>
      _fail();
  @override
  Future<List<ManualBusyBlock>> myBlocks(String t) async => <ManualBusyBlock>[];
  @override
  Future<List<CalendarFeed>> myFeeds() async => <CalendarFeed>[];
  @override
  Future<void> syncFeeds(String t, {String? url, String? label}) async =>
      _fail();
  @override
  Future<void> deleteFeed(String f) async => _fail();
}

final Provider<AvailabilityRepository> availabilityRepositoryProvider =
    Provider<AvailabilityRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredAvailabilityRepository();
  return SupabaseAvailabilityRepository(client);
});

final FutureProviderFamily<List<DayAvailability>, String> availabilityProvider =
    FutureProvider.family<List<DayAvailability>, String>((Ref ref, String id) {
  return ref.watch(availabilityRepositoryProvider).forTrip(id);
});

/// The caller's own blocks — imported and hand-entered alike — for
/// prefilling the availability editor.
final FutureProviderFamily<List<ManualBusyBlock>, String> myBlocksProvider =
    FutureProvider.family<List<ManualBusyBlock>, String>((Ref ref, String id) {
  return ref.watch(availabilityRepositoryProvider).myBlocks(id);
});

/// Subscribed iCal links. Not per trip — a feed belongs to the person, and
/// every trip they join reuses it.
final FutureProvider<List<CalendarFeed>> myFeedsProvider =
    FutureProvider<List<CalendarFeed>>((Ref ref) {
  return ref.watch(availabilityRepositoryProvider).myFeeds();
});
