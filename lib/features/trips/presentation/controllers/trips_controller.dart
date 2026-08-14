import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/trip_repository_impl.dart';
import '../../domain/trip.dart';
import '../../domain/trip_repository.dart';
import 'trip_invalidation.dart';

final FutureProvider<List<Trip>> myTripsProvider =
    FutureProvider<List<Trip>>((Ref ref) {
  return ref.watch(tripRepositoryProvider).myTrips();
});

final FutureProviderFamily<Trip, String> tripProvider =
    FutureProvider.family<Trip, String>((Ref ref, String id) {
  return ref.watch(tripRepositoryProvider).byId(id);
});

/// Owns creation. Returns the new id so the caller can navigate straight into
/// the trip — the moment after creating is when the organiser most wants to
/// share the link, so we must not drop them back on a list.
class CreateTripController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  Future<String?> submit(NewTrip draft) async {
    state = const AsyncLoading<void>();
    final AsyncValue<String> result = await AsyncValue.guard(
      () => ref.read(tripRepositoryProvider).create(draft),
    );
    state = result.hasError
        ? AsyncError<void>(result.error!, result.stackTrace!)
        : const AsyncData<void>(null);

    if (result.hasError) return null;
    ref.invalidate(myTripsProvider);
    return result.requireValue;
  }
}

final AsyncNotifierProvider<CreateTripController, void>
    createTripControllerProvider =
    AsyncNotifierProvider<CreateTripController, void>(CreateTripController.new);

/// Owns editing.
///
/// Zneplatňuje víc providerů než by se zdálo nutné, a je to schválně: plán,
/// náklady i balení jsou čtecí funkce nad výletem, takže po změně délky nebo
/// aktivit jsou všechny tři zastaralé najednou. Nechat je viset by ukázalo
/// pláštěnku na den, na který se už nejede.
class UpdateTripController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  Future<bool> submit(String tripId, Map<String, Object?> patch) async {
    if (patch.isEmpty) return true;

    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(() async {
      await ref.read(tripRepositoryProvider).update(tripId, patch);
      invalidateTripDerived(ref, tripId);
    });
    return !state.hasError;
  }
}

final AsyncNotifierProvider<UpdateTripController, void>
    updateTripControllerProvider =
    AsyncNotifierProvider<UpdateTripController, void>(
  UpdateTripController.new,
);
