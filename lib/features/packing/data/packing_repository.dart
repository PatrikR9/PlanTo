import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
import '../../../core/error/failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/packing_item.dart';

abstract interface class PackingRepository {
  Future<List<PackingItem>> forTrip(String tripId);
  Future<void> setChecked(
    String tripId,
    String itemKey, {
    required bool checked,
  });
}

class SupabasePackingRepository implements PackingRepository {
  const SupabasePackingRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<PackingItem>> forTrip(String tripId) => guard(() async {
        final List<dynamic> rows = await _client.rpc<List<dynamic>>(
          'build_packing_list',
          params: <String, dynamic>{'p_trip': tripId},
        );
        return rows
            .cast<Map<String, dynamic>>()
            .map(PackingItem.fromRow)
            .whereType<PackingItem>()
            .toList();
      });

  @override
  Future<void> setChecked(
    String tripId,
    String itemKey, {
    required bool checked,
  }) =>
      guard(() async {
        await _client.rpc<void>(
          'set_packing_checked',
          params: <String, dynamic>{
            'p_trip': tripId,
            'p_item': itemKey,
            'p_checked': checked,
          },
        );
      });
}

class UnconfiguredPackingRepository implements PackingRepository {
  const UnconfiguredPackingRepository();

  @override
  Future<List<PackingItem>> forTrip(String t) async => <PackingItem>[];

  @override
  Future<void> setChecked(String t, String i, {required bool checked}) async =>
      throw const ServerFailure(code: 'NO_BACKEND');
}

final Provider<PackingRepository> packingRepositoryProvider =
    Provider<PackingRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredPackingRepository();
  return SupabasePackingRepository(client);
});

/// The list itself. Ticking an item does not re-fetch it — see
/// [PackingController], which keeps the tick local so the checkbox responds
/// in the same frame the finger lifts.
final FutureProviderFamily<List<PackingItem>, String> packingListProvider =
    FutureProvider.family<List<PackingItem>, String>((Ref ref, String id) {
  return ref.watch(packingRepositoryProvider).forTrip(id);
});
