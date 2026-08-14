import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/packing_repository.dart';
import '../domain/packing_item.dart';

/// Ticking an item, optimistically.
///
/// Deliberately not `invalidate(packingListProvider)` after every tap. That
/// would rebuild the list from the server on each checkbox, which means a
/// round trip before the tick appears — and a packing list is used standing in
/// a hallway with one hand full, ticking six things in ten seconds. The state
/// changes in the same frame the finger lifts; the write follows.
///
/// If the write fails the tick is put back and the error surfaces, because a
/// checkbox that silently un-ticks itself later is worse than one that never
/// moved.
class PackingController extends FamilyAsyncNotifier<List<PackingItem>, String> {
  @override
  Future<List<PackingItem>> build(String tripId) {
    return ref.watch(packingRepositoryProvider).forTrip(tripId);
  }

  Future<bool> toggle(PackingItem item) async {
    final List<PackingItem>? current = state.valueOrNull;
    if (current == null) return false;

    final bool next = !item.checked;
    state = AsyncData<List<PackingItem>>(<PackingItem>[
      for (final PackingItem i in current)
        if (i.itemKey == item.itemKey) i.copyWith(checked: next) else i,
    ]);

    try {
      await ref
          .read(packingRepositoryProvider)
          .setChecked(arg, item.itemKey, checked: next);
      return true;
    } on Object catch (e) {
      state = AsyncData<List<PackingItem>>(current);
      // The failure still has to reach somebody. Setting AsyncError here would
      // blank the whole list because one checkbox failed, so the screen
      // watches this instead and shows a snackbar over the list it still has.
      ref.read(packingErrorProvider.notifier).state = e;
      return false;
    }
  }
}

final AsyncNotifierProviderFamily<PackingController, List<PackingItem>, String>
    packingControllerProvider =
    AsyncNotifierProvider.family<PackingController, List<PackingItem>, String>(
  PackingController.new,
);

/// Last write failure, consumed and cleared by the screen.
final StateProvider<Object?> packingErrorProvider =
    StateProvider<Object?>((Ref ref) => null);
