import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/transit_stop.dart';

/// Hledání zastávek.
///
/// Celé na serveru. Databáze má desítky tisíc zastávek a stáhnout ji do
/// klienta by znamenalo posílat megabajty kvůli jednomu výběru — proto je
/// `transit_places` bez select policy a ven vede jenom RPC.
abstract interface class StopSearchRepository {
  /// [near] je volitelné. Když polohu známe, blízké zastávky jdou nahoru;
  /// když ne, hledá se stejně dobře, jen bez toho bonusu.
  Future<List<TransitStop>> search(
    String query, {
    ({double lat, double lon})? near,
    int limit,
  });

  /// Načte uložený výběr. Výlet drží ID; na jiném zařízení je to jediný
  /// způsob, jak k němu dostat jméno a souřadnice.
  Future<TransitStop?> byId(String id);

  /// Je databáze zastávek naimportovaná?
  ///
  /// Prázdná databáze a „nic jsme nenašli" vypadají v UI stejně a nejsou
  /// totéž. Mezi migrací a prvním během importu je hledání legitimně prázdné
  /// a obrazovka to musí umět říct — jinak se to hledá jako chyba v hledání.
  Future<bool> hasData();
}

class SupabaseStopSearchRepository implements StopSearchRepository {
  const SupabaseStopSearchRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<TransitStop>> search(
    String query, {
    ({double lat, double lon})? near,
    int limit = 12,
  }) =>
      guard(() async {
        final List<dynamic> rows = await _client.rpc<List<dynamic>>(
          'search_transit_stops',
          params: <String, dynamic>{
            'p_query': query,
            'p_lat': near?.lat,
            'p_lon': near?.lon,
            'p_limit': limit,
          },
        );
        return rows
            .cast<Map<String, dynamic>>()
            .map(TransitStop.fromRow)
            .toList();
      });

  @override
  Future<TransitStop?> byId(String id) => guard(() async {
        final List<dynamic> rows = await _client.rpc<List<dynamic>>(
          'transit_place',
          params: <String, dynamic>{'p_id': id},
        );
        if (rows.isEmpty) return null;
        return TransitStop.fromRow(rows.first as Map<String, dynamic>);
      });

  @override
  Future<bool> hasData() => guard(() async {
        final List<dynamic> rows =
            await _client.rpc<List<dynamic>>('transit_data_status');
        if (rows.isEmpty) return false;
        final Map<String, dynamic> r = rows.first as Map<String, dynamic>;
        return ((r['places'] as num?) ?? 0) > 0;
      });
}

/// Bez backendu vrací prázdno, ne výjimku.
///
/// Hledání zastávek je vyhledávací pole — prázdný výsledek je jeho normální
/// stav a obrazovka se s ním umí vypořádat. Vyhodit tady chybu by znamenalo
/// červený pruh při každém stisku klávesy v lokálním režimu.
class UnconfiguredStopSearchRepository implements StopSearchRepository {
  const UnconfiguredStopSearchRepository();

  @override
  Future<List<TransitStop>> search(
    String query, {
    ({double lat, double lon})? near,
    int limit = 12,
  }) async =>
      const <TransitStop>[];

  @override
  Future<TransitStop?> byId(String id) async => null;

  @override
  Future<bool> hasData() async => false;
}

final Provider<StopSearchRepository> stopSearchRepositoryProvider =
    Provider<StopSearchRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredStopSearchRepository();
  return SupabaseStopSearchRepository(client);
});
