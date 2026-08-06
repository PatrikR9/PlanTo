import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
import '../../../core/error/failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/trip.dart';
import '../domain/trip_repository.dart';

/// Columns read from the `trips_list` view. Listed explicitly rather than `*`
/// so adding a column server-side cannot silently change payload size.
const String _tripColumns = '''
id, title, description, status, origin_label, window_start, window_end,
duration_days, transport, budget_per_person, currency, activity_tags,
earliest_wake, destination_id, destination_free,
destination_lat, destination_lon, created_by,
participant_count, calendar_shared_count, locked_start, locked_end, my_role,
granularity, slot_minutes, slot_step_minutes, day_start, day_end
''';

class SupabaseTripRepository implements TripRepository {
  const SupabaseTripRepository(this._client);

  final SupabaseClient _client;

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

  @override
  Future<String> create(NewTrip draft) => guard(() async {
        final dynamic id = await _client.rpc<dynamic>(
          'create_trip',
          params: <String, dynamic>{
            'p_title': draft.title,
            'p_origin_label': draft.originLabel,
            'p_origin_lat': draft.originLat,
            'p_origin_lon': draft.originLon,
            'p_window_start': draft.windowStart.toUtc().toIso8601String(),
            'p_window_end': draft.windowEnd.toUtc().toIso8601String(),
            'p_duration_days': draft.durationDays,
            'p_transport': draft.transport.name,
            'p_budget_per_person': draft.budgetPerPerson,
            // .wire, never .name. The Dart constant may be renamed or written
            // in camelCase; the string in the database is a contract shared
            // with the packing rules.
            'p_activity_tags':
                draft.activityTags.map((ActivityTag t) => t.wire).toList(),
            'p_description': draft.description,
            'p_earliest_wake': _timeOfDay(draft.earliestWake),
            'p_currency': draft.currency,
            'p_granularity': draft.granularity.wire,
            'p_slot_minutes': draft.slotMinutes,
            'p_slot_step_minutes': draft.slotStepMinutes,
            'p_day_start': _timeOfDay(draft.dayStart),
            'p_day_end': _timeOfDay(draft.dayEnd),
          },
        );
        return id as String;
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
    title: row['title'] as String,
    description: row['description'] as String?,
    status: _status(row['status'] as String),
    originLabel: row['origin_label'] as String,
    windowStart: DateTime.parse(row['window_start'] as String).toLocal(),
    windowEnd: DateTime.parse(row['window_end'] as String).toLocal(),
    durationDays: (row['duration_days'] as int?) ?? 1,
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
    participantCount: (row['participant_count'] as int?) ?? 0,
    calendarSharedCount: (row['calendar_shared_count'] as int?) ?? 0,
    createdBy: row['created_by'] as String,
    isOrganiser: row['my_role'] == 'organiser',
    granularity: TripGranularity.fromWire(row['granularity'] as String?),
    slotMinutes: row['slot_minutes'] as int?,
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
  Future<Trip> byId(String id) async => _fail();
  @override
  Future<String> create(NewTrip draft) async => _fail();
}

final Provider<TripRepository> tripRepositoryProvider =
    Provider<TripRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredTripRepository();
  return SupabaseTripRepository(client);
});
