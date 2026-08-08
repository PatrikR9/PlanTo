import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
import '../../../core/error/failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/transport_option.dart';

abstract interface class TransportRepository {
  /// Empty when the trip has no destination yet, which is the normal state of
  /// a trip being planned and not an error.
  Future<List<TransportOption>> options(String tripId);

  Future<void> setDestination(
    String tripId, {
    required String label,
    double? lat,
    double? lon,
  });

  /// Cíl jako konkrétní zastávka.
  ///
  /// Vedle [setDestination], ne místo ní: volný název pořád potřebuje
  /// kurátorovaná destinace z tabulky `destinations`, která zastávku nemá.
  /// Server si z ID vytáhne jméno i souřadnice sám — posílat je zvlášť by
  /// znamenalo dvě verze pravdy o jednom místě.
  Future<void> setDestinationStop(String tripId, String stopId);
}

class SupabaseTransportRepository implements TransportRepository {
  const SupabaseTransportRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<TransportOption>> options(String tripId) => guard(() async {
        final List<dynamic> rows = await _client.rpc<List<dynamic>>(
          'transport_options',
          params: <String, dynamic>{'p_trip': tripId},
        );
        return rows
            .cast<Map<String, dynamic>>()
            .map(TransportOption.fromRow)
            .toList();
      });

  @override
  Future<void> setDestination(
    String tripId, {
    required String label,
    double? lat,
    double? lon,
  }) =>
      guard(() async {
        await _client.rpc<void>(
          'set_trip_destination',
          params: <String, dynamic>{
            'p_trip': tripId,
            'p_label': label,
            'p_lat': lat,
            'p_lon': lon,
          },
        );
      });

  @override
  Future<void> setDestinationStop(String tripId, String stopId) =>
      guard(() async {
        await _client.rpc<void>(
          'set_trip_destination_stop',
          params: <String, dynamic>{'p_trip': tripId, 'p_place': stopId},
        );
      });
}

class UnconfiguredTransportRepository implements TransportRepository {
  const UnconfiguredTransportRepository();

  @override
  Future<List<TransportOption>> options(String t) async => <TransportOption>[];
  @override
  Future<void> setDestination(
    String t, {
    required String label,
    double? lat,
    double? lon,
  }) async =>
      throw const ServerFailure(code: 'NO_BACKEND');
  @override
  Future<void> setDestinationStop(String t, String s) async =>
      throw const ServerFailure(code: 'NO_BACKEND');
}

final Provider<TransportRepository> transportRepositoryProvider =
    Provider<TransportRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredTransportRepository();
  return SupabaseTransportRepository(client);
});

final FutureProviderFamily<List<TransportOption>, String>
    transportOptionsProvider =
    FutureProvider.family<List<TransportOption>, String>((Ref ref, String id) {
  return ref.watch(transportRepositoryProvider).options(id);
});
