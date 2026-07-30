import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/trips/domain/trip.dart';

Trip make({int participants = 3, int shared = 3, TripStatus status = TripStatus.planning}) {
  return Trip(
    id: 't',
    title: 'Test',
    status: status,
    originLabel: 'Praha',
    windowStart: DateTime(2026, 9, 11),
    windowEnd: DateTime(2026, 9, 15),
    durationDays: 1,
    transport: TransportPref.public,
    currency: 'CZK',
    activityTags: const <ActivityTag>[],
    participantCount: participants,
    calendarSharedCount: shared,
    createdBy: 'u',
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
  });
}
