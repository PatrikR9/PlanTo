import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/availability_repository.dart';
import '../data/device_calendar_source.dart';
import '../domain/busy_interval.dart';
import '../domain/calendar_source.dart';
import '../../trips/presentation/controllers/trips_controller.dart';

/// Runs the whole sync: permission → read → reduce → upload.
///
/// Everything before `uploadMine` happens on the device. What leaves it is a
/// handful of start/end pairs.
class CalendarSyncController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  Future<bool> sync({
    required String tripId,
    required DateTime windowStart,
    required DateTime windowEnd,
    List<String>? calendarIds,
  }) async {
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(() async {
      final CalendarSource source = ref.read(calendarSourceProvider);

      if (!await source.hasPermission()) {
        final bool granted = await source.requestPermission();
        if (!granted) return;
      }

      final List<CalendarInfo> all = await source.calendars();
      final List<String> ids = calendarIds ??
          all
              .where((CalendarInfo c) => c.suggestedByDefault)
              .map((CalendarInfo c) => c.id)
              .toList();

      final List<BusyInterval> raw = await source.busyBlocks(
        from: windowStart,
        to: windowEnd,
        calendarIds: ids,
      );

      final List<BusyInterval> prepared = BusyIntervals.prepare(
        raw,
        windowStart: windowStart,
        windowEnd: windowEnd,
      );

      final AvailabilityRepository repo =
          ref.read(availabilityRepositoryProvider);
      await repo.uploadMine(tripId, prepared);
      await repo.markShared(tripId);

      ref.invalidate(availabilityProvider(tripId));
      ref.invalidate(tripProvider(tripId));
      ref.invalidate(myTripsProvider);
    });

    return !state.hasError;
  }

  /// Immediate deletion, no soft delete, no grace period. The privacy screen
  /// promises exactly this.
  Future<void> disconnect(String tripId) async {
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(() async {
      await ref.read(availabilityRepositoryProvider).deleteMine(tripId);
      ref.invalidate(availabilityProvider(tripId));
      ref.invalidate(tripProvider(tripId));
    });
  }
}

final AsyncNotifierProvider<CalendarSyncController, void>
    calendarSyncControllerProvider =
    AsyncNotifierProvider<CalendarSyncController, void>(
        CalendarSyncController.new);
