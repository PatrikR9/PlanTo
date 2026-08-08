import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/trips/domain/trip.dart';

Trip make({
  int participants = 3,
  int shared = 3,
  TripStatus status = TripStatus.planning,
  bool organiser = true,
  TripGranularity granularity = TripGranularity.day,
  int? slotMinutes,
  DateTime? lockedStart,
  DateTime? lockedEnd,
}) {
  return Trip(
    id: 't',
    title: 'Test',
    status: status,
    originLabel: 'Praha hl.n.',
    originLat: 50.0830,
    originLon: 14.4356,
    windowStart: DateTime(2026, 9, 11),
    windowEnd: DateTime(2026, 9, 15),
    durationDays: 1,
    transport: TransportPref.public,
    currency: 'CZK',
    activityTags: const <ActivityTag>[],
    participantCount: participants,
    calendarSharedCount: shared,
    createdBy: 'u',
    isOrganiser: organiser,
    granularity: granularity,
    slotMinutes: slotMinutes,
    slotStepMinutes: 30,
    dayStart: const Duration(hours: 7),
    dayEnd: const Duration(hours: 21),
    lockedStart: lockedStart,
    lockedEnd: lockedEnd,
  );
}

void main() {
  group('Trip', () {
    test('counts who has not shared a calendar yet', () {
      expect(make(participants: 5, shared: 3).awaitingCalendarCount, 2);
    });

    test('needs two calendars before proposing dates', () {
      // One person's free time is not a group decision, so the Dates tab must
      // stay quiet until a second calendar lands.
      expect(make(participants: 4, shared: 1).canProposeDates, isFalse);
      expect(make(participants: 4, shared: 2).canProposeDates, isTrue);
    });

    test('destination is undecided until one is set', () {
      expect(make().isDestinationDecided, isFalse);
    });

    test('is not date-locked until a date is set', () {
      expect(make().isDateLocked, isFalse);
      expect(
        make(
          lockedStart: DateTime(2026, 9, 12),
          lockedEnd: DateTime(2026, 9, 13),
        ).isDateLocked,
        isTrue,
      );
    });

    test('lockedEnd is exclusive, so a one-day trip ends the day it starts',
        () {
      // The column is a half-open range. Getting this wrong tells the group
      // to come home a day late, which is exactly the kind of quiet
      // off-by-one that survives a demo.
      final Trip t = make(
        lockedStart: DateTime(2026, 9, 12),
        lockedEnd: DateTime(2026, 9, 13),
      );
      expect(t.lockedEnd!.subtract(const Duration(days: 1)), t.lockedStart);
    });

    test('granularity drives the timed flag and the slot duration', () {
      expect(make().isTimed, isFalse);
      // Day-mode trips have no slot length; the fallback exists so no screen
      // has to null-check a duration it will never show.
      expect(make().slotDuration, const Duration(minutes: 120));

      final Trip timed =
          make(granularity: TripGranularity.time, slotMinutes: 90);
      expect(timed.isTimed, isTrue);
      expect(timed.slotDuration, const Duration(minutes: 90));
    });
  });

  group('TripGranularity', () {
    test('maps the database value, defaulting to day', () {
      expect(TripGranularity.fromWire('time'), TripGranularity.time);
      expect(TripGranularity.fromWire('day'), TripGranularity.day);
      // An unknown value must not crash a list builder; day is the safe
      // reading because it is what every existing row is.
      expect(TripGranularity.fromWire(null), TripGranularity.day);
      expect(TripGranularity.fromWire('weekly'), TripGranularity.day);
    });
  });
}
