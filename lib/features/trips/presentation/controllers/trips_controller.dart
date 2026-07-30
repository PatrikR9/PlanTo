import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/trip_repository_impl.dart';
import '../../domain/trip.dart';
import '../../domain/trip_repository.dart';

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
