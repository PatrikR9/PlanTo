import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/cost_line.dart';

abstract interface class CostRepository {
  /// Empty when the trip has no destination yet — the same normal state the
  /// Plan tab handles, not an error.
  Future<CostEstimate> estimate(String tripId);
}

class SupabaseCostRepository implements CostRepository {
  const SupabaseCostRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<CostEstimate> estimate(String tripId) => guard(() async {
        final List<dynamic> rows = await _client.rpc<List<dynamic>>(
          'estimate_trip_cost',
          params: <String, dynamic>{'p_trip': tripId},
        );
        return CostEstimate(
          rows
              .cast<Map<String, dynamic>>()
              .map(CostLine.fromRow)
              .whereType<CostLine>()
              .toList(),
        );
      });
}

class UnconfiguredCostRepository implements CostRepository {
  const UnconfiguredCostRepository();

  @override
  Future<CostEstimate> estimate(String t) async =>
      const CostEstimate(<CostLine>[]);
}

final Provider<CostRepository> costRepositoryProvider =
    Provider<CostRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredCostRepository();
  return SupabaseCostRepository(client);
});

final FutureProviderFamily<CostEstimate, String> costEstimateProvider =
    FutureProvider.family<CostEstimate, String>((Ref ref, String id) {
  return ref.watch(costRepositoryProvider).estimate(id);
});
