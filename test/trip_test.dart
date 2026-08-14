import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/trips/domain/trip.dart';

Trip make({
  int participants = 3,
  int shared = 3,
  TripStatus status = TripStatus.planning,
  bool organiser = true,
  TripKind kind = TripKind.trip,
  int durationMinutes = 1440,
  DateTime? lockedStart,
  DateTime? lockedEnd,
}) {
  return Trip(
    id: 't',
    kind: kind,
    title: 'Test',
    status: status,
    originLabel: kind == TripKind.meeting ? '' : 'Praha hl.n.',
    originLat: 50.0830,
    originLon: 14.4356,
    windowStart: DateTime(2026, 9, 11),
    windowEnd: DateTime(2026, 9, 15),
    durationMinutes: durationMinutes,
    transport: TransportPref.public,
    currency: 'CZK',
    activityTags: const <ActivityTag>[],
    participantCount: participants,
    calendarSharedCount: shared,
    createdBy: 'u',
    isOrganiser: organiser,
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
  });

  group('délka výletu', () {
    // Tahle trojice je odvozená ze stejného čísla jako trigger v databázi.
    // Kdyby se ti dva rozešli, klient by nabízel jiná pole, než jaká server
    // použije — a poznalo by se to až na termínech, které nesedí.
    test('pod jeden den se hledá čas, od jednoho dne celé dny', () {
      expect(make(durationMinutes: 1439).isTimed, isTrue);
      expect(make(durationMinutes: 1440).isTimed, isFalse);
    });

    test('slot existuje právě v hodinovém módu', () {
      expect(make(durationMinutes: 90).slotMinutes, 90);
      expect(make(durationMinutes: 2880).slotMinutes, isNull);
      // Fallback, aby žádná obrazovka nemusela null-checkovat délku, kterou
      // stejně nikdy nezobrazí.
      expect(
        make(durationMinutes: 2880).slotDuration,
        const Duration(minutes: 120),
      );
    });

    test('dny se zaokrouhlují nahoru', () {
      // Čtyřicet hodin zabere dva dny, ne den a půl. Dolní zaokrouhlení by
      // navrhlo termín, ze kterého se skupina vrátí až druhý den.
      expect(make(durationMinutes: 120).durationDays, 1);
      expect(make(durationMinutes: 1440).durationDays, 1);
      expect(make(durationMinutes: 1441).durationDays, 2);
      expect(make(durationMinutes: 2880).durationDays, 2);
      expect(make(durationMinutes: 10080).durationDays, 7);
    });
  });

  group('TripKind', () {
    test('maps the database value, defaulting to trip', () {
      expect(TripKind.fromWire('meeting'), TripKind.meeting);
      expect(TripKind.fromWire('trip'), TripKind.trip);
      // Neznámá hodnota nesmí shodit seznam; výlet je bezpečné čtení, protože
      // je to všechno, co v databázi bylo před M13.
      expect(TripKind.fromWire(null), TripKind.trip);
      expect(TripKind.fromWire('holiday'), TripKind.trip);
    });

    test('setkání nemá původ ani cíl', () {
      final Trip m = make(kind: TripKind.meeting);
      expect(m.isMeeting, isTrue);
      expect(m.originLabel, isEmpty);
      expect(m.isDestinationDecided, isFalse);
    });
  });
}
