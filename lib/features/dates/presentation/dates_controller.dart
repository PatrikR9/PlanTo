import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../packing/presentation/packing_controller.dart';
import '../../planner/presentation/plan_controller.dart';
import '../../trips/presentation/controllers/trips_controller.dart';
import '../data/date_repository.dart';
import '../domain/date_candidate.dart';

/// Owns the three mutations on the Dates tab.
///
/// One controller rather than three because they all invalidate the same two
/// providers, and because only one of them may be in flight at a time — a
/// vote landing while a lock is being written would show the user a state
/// that existed for 200 ms on the server and never again.
class DatesController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  Future<bool> vote({
    required String tripId,
    required DateTime startsAt,
    required DateVote? vote,
  }) {
    return _run(
      tripId,
      () => ref.read(dateRepositoryProvider).vote(tripId, startsAt, vote),
    );
  }

  Future<bool> lock({required String tripId, required DateTime startsAt}) {
    return _run(
      tripId,
      () => ref.read(dateRepositoryProvider).lock(tripId, startsAt),
      // Locking changes trips.status and trips.locked_range, so the trip
      // header and the trips list are both stale afterwards.
      alsoRefreshTrip: true,
    );
  }

  Future<bool> unlock({required String tripId}) {
    return _run(
      tripId,
      () => ref.read(dateRepositoryProvider).unlock(tripId),
      alsoRefreshTrip: true,
    );
  }

  Future<bool> _run(
    String tripId,
    Future<void> Function() body, {
    bool alsoRefreshTrip = false,
  }) async {
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(() async {
      await body();
      ref.invalidate(dateCandidatesProvider(tripId));
      if (alsoRefreshTrip) {
        ref.invalidate(tripProvider(tripId));
        ref.invalidate(myTripsProvider);
        // Locking a date fixes which day the forecast is for, and roughly a
        // third of the packing rules are predicates on that forecast. Leaving
        // it stale would show a raincoat for a day the group is no longer
        // going on.
        ref.invalidate(packingControllerProvider(tripId));
        // Plán stojí na zamčeném termínu — bez tohohle si drží kontext
        // z doby, kdy žádný termín nebyl, a záložka dál nabízí „nejdřív
        // vyberte termín" nad výletem, který termín má.
        ref.invalidate(planControllerProvider(tripId));
      }
    });
    return !state.hasError;
  }
}

final AsyncNotifierProvider<DatesController, void> datesControllerProvider =
    AsyncNotifierProvider<DatesController, void>(DatesController.new);
