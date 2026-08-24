import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
import '../../../core/error/failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/trip.dart';
import '../domain/trip_member.dart';
import '../domain/trip_repository.dart';

/// Columns read from the `trips_list` view. Listed explicitly rather than `*`
/// so adding a column server-side cannot silently change payload size.
const String _tripColumns = '''
id, kind, title, description, status, origin_label, origin_lat, origin_lon,
origin_place_id, window_start, window_end,
duration_minutes, transport, budget_per_person, currency, activity_tags,
earliest_wake, destination_id, destination_free,
destination_lat, destination_lon, destination_place_id, created_by,
participant_count, calendar_shared_count, locked_start, locked_end, my_role,
slot_step_minutes, day_start, day_end
''';

class SupabaseTripRepository implements TripRepository {
  const SupabaseTripRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<TripMember>> members(String tripId) => guard(() async {
        final List<dynamic> rows = await _client.rpc<List<dynamic>>(
          'trip_members',
          params: <String, dynamic>{'p_trip': tripId},
        );
        return rows
            .cast<Map<String, dynamic>>()
            .map(TripMember.fromRow)
            .toList();
      });

  @override
  Future<List<Trip>> myTrips() => guard(() async {
        final List<Map<String, dynamic>> rows = await _client
            .from('trips_list')
            .select(_tripColumns)
            .order('window_start', ascending: true);
        return rows.map(_toTrip).toList();
      });

  @override
  Future<Trip> byId(String id) => guard(() async {
        final Map<String, dynamic> row = await _client
            .from('trips_list')
            .select(_tripColumns)
            .eq('id', id)
            .single();
        return _toTrip(row);
      });

  // Jeden jsonb parametr místo devatenácti pojmenovaných. create_trip mělo
  // signaturu, kterou každé nové pole nutilo dropnout — a drop bere s sebou
  // grant, což vypadá jako chyba v aplikaci. Tenhle tvar se už nezmění.
  @override
  Future<String> create(NewTrip draft) => guard(() async {
        final dynamic id = await _client.rpc<dynamic>(
          'create_trip',
          params: <String, dynamic>{
            'p': <String, dynamic>{
              'kind': draft.kind.wire,
              'title': draft.title,
              'description': draft.description,
              'origin_label': draft.originLabel,
              'origin_lat': draft.originLat,
              'origin_lon': draft.originLon,
              'origin_place': draft.originPlaceId,
              'window_start': draft.windowStart.toUtc().toIso8601String(),
              'window_end': draft.windowEnd.toUtc().toIso8601String(),
              'duration_minutes': draft.durationMinutes,
              'transport': draft.transport.name,
              'budget_per_person': draft.budgetPerPerson,
              // .wire, never .name. The Dart constant may be renamed or
              // written in camelCase; the string in the database is a
              // contract shared with the packing rules.
              'activity_tags':
                  draft.activityTags.map((ActivityTag t) => t.wire).toList(),
              'earliest_wake': _timeOfDay(draft.earliestWake),
              'currency': draft.currency,
              'slot_step_minutes': draft.slotStepMinutes,
              'day_start': _timeOfDay(draft.dayStart),
              'day_end': _timeOfDay(draft.dayEnd),
            },
          },
        );
        return id as String;
      });

  @override
  Future<void> update(String id, Map<String, Object?> patch) => guard(() async {
        if (patch.isEmpty) return;
        await _client.rpc<dynamic>(
          'update_trip',
          params: <String, dynamic>{'p_trip': id, 'p_patch': patch},
        );
      });
}

String? _timeOfDay(Duration? d) {
  if (d == null) return null;
  final String h = d.inHours.toString().padLeft(2, '0');
  final String m = (d.inMinutes % 60).toString().padLeft(2, '0');
  return '$h:$m:00';
}

Trip _toTrip(Map<String, dynamic> row) {
  return Trip(
    id: row['id'] as String,
    kind: TripKind.fromWire(row['kind'] as String?),
    title: row['title'] as String,
    description: row['description'] as String?,
    status: _status(row['status'] as String),
    // Setkání nemá původ. Prázdný řetězec, ne null, aby žádná obrazovka
    // nemusela null-checkovat pole, které u výletu nikdy prázdné není.
    originLabel: (row['origin_label'] as String?) ?? '',
    originLat: ((row['origin_lat'] as num?) ?? 0).toDouble(),
    originLon: ((row['origin_lon'] as num?) ?? 0).toDouble(),
    originPlaceId: row['origin_place_id'] as String?,
    windowStart: DateTime.parse(row['window_start'] as String).toLocal(),
    windowEnd: DateTime.parse(row['window_end'] as String).toLocal(),
    durationMinutes: (row['duration_minutes'] as int?) ?? 1440,
    transport: _transport(row['transport'] as String?),
    budgetPerPerson: (row['budget_per_person'] as num?)?.toDouble(),
    currency: (row['currency'] as String?) ?? 'CZK',
    activityTags: <ActivityTag>[
      for (final Object? t
          in (row['activity_tags'] as List<dynamic>? ?? const <dynamic>[]))
        if (_tag(t as String) case final ActivityTag tag) tag,
    ],
    earliestWake: _parseTime(row['earliest_wake'] as String?),
    destinationId: row['destination_id'] as String?,
    destinationFree: row['destination_free'] as String?,
    destinationLat: (row['destination_lat'] as num?)?.toDouble(),
    destinationLon: (row['destination_lon'] as num?)?.toDouble(),
    destinationPlaceId: row['destination_place_id'] as String?,
    participantCount: (row['participant_count'] as int?) ?? 0,
    calendarSharedCount: (row['calendar_shared_count'] as int?) ?? 0,
    createdBy: row['created_by'] as String,
    isOrganiser: row['my_role'] == 'organiser',
    slotStepMinutes: (row['slot_step_minutes'] as int?) ?? 30,
    dayStart:
        _parseTime(row['day_start'] as String?) ?? const Duration(hours: 7),
    dayEnd: _parseTime(row['day_end'] as String?) ?? const Duration(hours: 21),
    // These are timestamptz now, not dates: in time mode the lock carries a
    // clock time, so toLocal() is right and dropping it would be wrong.
    lockedStart: _parseInstant(row['locked_start'] as String?),
    lockedEnd: _parseInstant(row['locked_end'] as String?),
  );
}

DateTime? _parseInstant(String? v) =>
    v == null ? null : DateTime.parse(v).toLocal();

TripStatus _status(String v) => switch (v) {
      'draft' => TripStatus.draft,
      'planning' => TripStatus.planning,
      'date_locked' => TripStatus.dateLocked,
      'confirmed' => TripStatus.confirmed,
      'completed' => TripStatus.completed,
      'cancelled' => TripStatus.cancelled,
      _ => TripStatus.planning,
    };

TransportPref _transport(String? v) => switch (v) {
      'public' => TransportPref.public,
      'car' => TransportPref.car,
      _ => TransportPref.either,
    };

ActivityTag? _tag(String v) => ActivityTag.fromWire(v);

Duration? _parseTime(String? v) {
  if (v == null) return null;
  final List<String> parts = v.split(':');
  if (parts.length < 2) return null;
  return Duration(
    hours: int.tryParse(parts[0]) ?? 0,
    minutes: int.tryParse(parts[1]) ?? 0,
  );
}

class UnconfiguredTripRepository implements TripRepository {
  const UnconfiguredTripRepository();
  Never _fail() => throw const ServerFailure(code: 'NO_BACKEND');

  @override
  Future<List<Trip>> myTrips() async => <Trip>[];
  @override
  Future<List<TripMember>> members(String tripId) async => <TripMember>[];
  @override
  Future<Trip> byId(String id) async => _fail();
  @override
  Future<String> create(NewTrip draft) async => _fail();
  @override
  Future<void> update(String id, Map<String, Object?> patch) async => _fail();
}

final Provider<TripRepository> tripRepositoryProvider =
    Provider<TripRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredTripRepository();
  return SupabaseTripRepository(client);
});
