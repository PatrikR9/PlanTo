import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
import '../../../core/error/failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/date_candidate.dart';

abstract interface class DateRepository {
  Future<List<DateCandidate>> candidates(String tripId);

  /// Všechny časy jednoho dne, nesloučené. Jen pro časový režim; v denním
  /// vrací prázdno, protože tam „slot" znamená celý den.
  Future<List<DateCandidate>> daySlots(String tripId, DateTime day);

  /// Warms the forecast cache for this trip.
  ///
  /// Cheap and idempotent: the Edge Function returns immediately unless
  /// something in range is missing or older than six hours, so calling it on
  /// every load costs one round trip and no Open-Meteo request.
  Future<void> refreshWeather(String tripId);

  /// [vote] null withdraws. Withdrawing is a first-class action: "I clicked
  /// the wrong thing" is more common than any of the three answers.
  Future<void> vote(String tripId, DateTime startsAt, DateVote? vote);

  Future<void> lock(String tripId, DateTime startsAt);
  Future<void> unlock(String tripId);
}

/// Instants go over the wire as UTC ISO-8601. Sending local time would work
/// right up until somebody plans a trip across a DST boundary.
String _instant(DateTime d) => d.toUtc().toIso8601String();

class SupabaseDateRepository implements DateRepository {
  const SupabaseDateRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<DateCandidate>> candidates(String tripId) => guard(() async {
        final List<dynamic> rows = await _client.rpc<List<dynamic>>(
          'trip_candidates_local',
          params: <String, dynamic>{
            'p_trip': tripId,
            // Výchozích 20 řadí podle skóre, takže termíny, kde někdo nemůže,
            // vypadnou za těmi, kde můžou všichni — a filtr „neshoda" by pak
            // u delšího okna neměl co ukázat. Řádek je malý; strop je tu
            // proti runaway dotazu, ne kvůli šířce pásma.
            // 200, ne 60: mřížka se kreslí z těchhle běhů a useknutý seznam
            // by v ní nechal šedé díry, které vypadají jako „nevíme" místo
            // „nevešlo se do žebříčku". Řádek je malý; strop je proti
            // runaway dotazu, ne kvůli šířce pásma.
            'p_limit': 200,
          },
        );
        return rows.cast<Map<String, dynamic>>().map(_toCandidate).toList();
      });

  @override
  Future<List<DateCandidate>> daySlots(String tripId, DateTime day) =>
      guard(() async {
        final List<dynamic> rows = await _client.rpc<List<dynamic>>(
          'trip_day_slots_local',
          params: <String, dynamic>{
            'p_trip': tripId,
            // Datum, ne instant: funkce si den skládá v časové zóně výletu.
            'p_day': '${day.year.toString().padLeft(4, '0')}-'
                '${day.month.toString().padLeft(2, '0')}-'
                '${day.day.toString().padLeft(2, '0')}',
          },
        );
        return rows.cast<Map<String, dynamic>>().map(_toCandidate).toList();
      });

  @override
  Future<void> vote(String tripId, DateTime startsAt, DateVote? vote) =>
      guard(() async {
        await _client.rpc<void>(
          'cast_slot_vote',
          params: <String, dynamic>{
            'p_trip': tripId,
            'p_start': _instant(startsAt),
            'p_vote': vote?.wire,
          },
        );
      });

  @override
  Future<void> lock(String tripId, DateTime startsAt) => guard(() async {
        await _client.rpc<void>(
          'lock_trip_slot',
          params: <String, dynamic>{
            'p_trip': tripId,
            'p_start': _instant(startsAt),
          },
        );
      });

  @override
  Future<void> unlock(String tripId) => guard(() async {
        await _client.rpc<void>(
          'unlock_trip_slot',
          params: <String, dynamic>{'p_trip': tripId},
        );
      });

  @override
  Future<void> refreshWeather(String tripId) => guard(() async {
        await _client.functions.invoke(
          'weather',
          body: <String, dynamic>{'trip_id': tripId},
        );
      });
}

DateCandidate _toCandidate(Map<String, dynamic> r) {
  return DateCandidate(
    // timestamptz, so toLocal() is required: in time mode the clock time is
    // the whole point of the candidate.
    startsAt: DateTime.parse(r['starts_at'] as String).toLocal(),
    endsAt: DateTime.parse(r['ends_at'] as String).toLocal(),
    // trip_day_slots tenhle sloupec nevrací: slot žádný „zbytek okna" nemá,
    // je to jeden krok mřížky. Bez fallbacku by mapování spadlo na null.
    windowEndsAt: DateTime.parse(
      (r['window_ends_at'] ?? r['ends_at']) as String,
    ).toLocal(),
    // Bez zóny, takže DateTime.parse dá naivní čas — přesně to, co chceme:
    // je to už čas výletu a nesmí se znovu přepočítávat.
    localStart: _local(r, 'local_starts_at', r['starts_at'] as String),
    localEnd: _local(r, 'local_ends_at', r['ends_at'] as String),
    localWindowEnd: _local(
      r,
      'local_window_ends_at',
      (r['window_ends_at'] ?? r['ends_at']) as String,
    ),
    freeCount: (r['free_count'] as int?) ?? 0,
    totalCount: (r['total_count'] as int?) ?? 0,
    freeUserIds: (r['free_user_ids'] as List<dynamic>? ?? const <dynamic>[])
        .cast<String>(),
    busyUserIds: (r['busy_user_ids'] as List<dynamic>? ?? const <dynamic>[])
        .cast<String>(),
    isWeekend: (r['is_weekend'] as bool?) ?? false,
    isHoliday: (r['is_holiday'] as bool?) ?? false,
    score: ((r['score'] as num?) ?? 0).toDouble(),
    yesCount: (r['yes_count'] as int?) ?? 0,
    maybeCount: (r['maybe_count'] as int?) ?? 0,
    noCount: (r['no_count'] as int?) ?? 0,
    myVote: DateVote.fromWire(r['my_vote'] as String?),
    isLocked: (r['is_locked'] as bool?) ?? false,
    // Deliberately NOT defaulted to 0. Past the forecast horizon these are
    // null, and null has to survive all the way to the card.
    weatherScore: (r['weather_score'] as num?)?.round(),
    weatherCode: (r['weather_code'] as num?)?.toInt(),
    tempMax: (r['temp_max'] as num?)?.toDouble(),
    precipProb: (r['precip_prob'] as num?)?.toInt(),
    windGustKmh: (r['wind_gust_kmh'] as num?)?.toDouble(),
    sunrise: _parseInstant(r['sunrise'] as String?),
    sunset: _parseInstant(r['sunset'] as String?),
  );
}

/// Parses a timestamptz coming back from PostgREST. Named apart from
/// [_instant], which goes the other way — one `_instant` for both directions
/// compiled to a name clash, not an overload.
/// Místní čas výletu, s návratem k zóně zařízení, kdyby sloupec chyběl.
///
/// Fallback existuje kvůli jedinému případu: nasazený klient proti databázi
/// bez migrace 20260821140000. Špatný den je pořád lepší než prázdná
/// obrazovka, a je to stav, který sám zmizí po `supabase db push`.
DateTime _local(Map<String, dynamic> r, String key, String fallbackUtc) {
  final String? v = r[key] as String?;
  if (v != null && v.isNotEmpty) return DateTime.parse(v);
  return DateTime.parse(fallbackUtc).toLocal();
}

DateTime? _parseInstant(String? v) =>
    v == null ? null : DateTime.parse(v).toLocal();

class UnconfiguredDateRepository implements DateRepository {
  const UnconfiguredDateRepository();
  Never _fail() => throw const ServerFailure(code: 'NO_BACKEND');

  @override
  Future<List<DateCandidate>> candidates(String t) async => <DateCandidate>[];
  // Prázdno, ne _fail(): bez backendu se UI prohlíží a prázdný den je
  // legitimní stav obrazovky, ne chyba, kterou by měla hlásit.
  @override
  Future<List<DateCandidate>> daySlots(String t, DateTime d) async =>
      <DateCandidate>[];
  @override
  Future<void> vote(String t, DateTime s, DateVote? v) async => _fail();
  @override
  Future<void> lock(String t, DateTime s) async => _fail();
  @override
  Future<void> unlock(String t) async => _fail();
  @override
  Future<void> refreshWeather(String t) async {}
}

final Provider<DateRepository> dateRepositoryProvider =
    Provider<DateRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredDateRepository();
  return SupabaseDateRepository(client);
});

/// Klíč pro [daySlotsProvider]. Record, protože rodina potřebuje hodnotovou
/// rovnost — a den se normalizuje na datum, aby dvě instance téhož dne
/// s jiným časem nezaložily dva různé dotazy.
typedef DaySlotsKey = ({String tripId, DateTime day});

DaySlotsKey daySlotsKey(String tripId, DateTime day) =>
    (tripId: tripId, day: DateTime(day.year, day.month, day.day));

/// Načítá se až po výběru dne, ne s obrazovkou: je to jeden dotaz na den,
/// který si někdo vybral, místo jednoho na každý den okna.
final FutureProviderFamily<List<DateCandidate>, DaySlotsKey> daySlotsProvider =
    FutureProvider.family<List<DateCandidate>, DaySlotsKey>(
        (Ref ref, DaySlotsKey k) {
  return ref.watch(dateRepositoryProvider).daySlots(k.tripId, k.day);
});

final FutureProviderFamily<List<DateCandidate>, String> dateCandidatesProvider =
    FutureProvider.family<List<DateCandidate>, String>(
        (Ref ref, String id) async {
  final DateRepository repo = ref.watch(dateRepositoryProvider);

  // Warm the forecast before ranking, but never let it decide whether the
  // screen works. A weather outage, a cold Edge Function or a rate limit must
  // degrade the ranking to availability-only — the deterministic engine is
  // the product, the forecast is a term in it.
  try {
    await repo.refreshWeather(id);
  } on Failure catch (_) {
    // Swallowed on purpose: _candidate_score renormalises when the weather
    // columns are null, so the list below is still correct, just less
    // informed. Surfacing this as an error state would be a lie about what
    // failed.
  }

  return repo.candidates(id);
});
