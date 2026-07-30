import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/availability/domain/manual_busy_block.dart';
import 'package:planto/features/dates/domain/date_candidate.dart';

DateCandidate make({
  int free = 3,
  int total = 4,
  DateVote? myVote,
  int yes = 0,
  int maybe = 0,
  int no = 0,
  bool locked = false,
  DateTime? startsAt,
  DateTime? endsAt,
  DateTime? windowEndsAt,
  int? weatherScore,
  int? weatherCode,
  DateTime? sunset,
}) {
  final DateTime s = startsAt ?? DateTime(2026, 9, 12, 14);
  final DateTime e = endsAt ?? s.add(const Duration(minutes: 90));
  return DateCandidate(
    startsAt: s,
    endsAt: e,
    windowEndsAt: windowEndsAt ?? e,
    freeCount: free,
    totalCount: total,
    freeUserIds: const <String>[],
    busyUserIds: const <String>[],
    isWeekend: true,
    isHoliday: false,
    score: 0.49,
    yesCount: yes,
    maybeCount: maybe,
    noCount: no,
    myVote: myVote,
    isLocked: locked,
    weatherScore: weatherScore,
    weatherCode: weatherCode,
    sunset: sunset,
  );
}

void main() {
  group('DateVote', () {
    test('round-trips through the database wire value', () {
      for (final DateVote v in DateVote.values) {
        expect(DateVote.fromWire(v.wire), v);
      }
    });

    test('an unknown or missing value is no vote, not a crash', () {
      // The RPC returns null for "you have not voted", and a future migration
      // could add a fourth value. Neither may throw in a list item builder.
      expect(DateVote.fromWire(null), isNull);
      expect(DateVote.fromWire('abstain'), isNull);
    });
  });

  group('DateCandidate', () {
    test('availability is a percentage of the group, rounded', () {
      expect(make(free: 3, total: 4).availabilityPercent, 75);
      expect(make(free: 2, total: 3).availabilityPercent, 67);
    });

    test('a trip with no participants does not divide by zero', () {
      expect(make(free: 0, total: 0).availabilityPercent, 0);
      expect(make(free: 0, total: 0).everyoneFree, isFalse);
    });

    test('counts votes cast, not participants', () {
      expect(make(yes: 2, maybe: 1, no: 1).votesCast, 4);
      expect(make().votesCast, 0);
    });

    test('day strips the clock, so grouping by day works in time mode', () {
      final DateCandidate a = make(startsAt: DateTime(2026, 9, 12, 9, 30));
      final DateCandidate b = make(startsAt: DateTime(2026, 9, 12, 17));
      expect(a.day, b.day);
      expect(a.day, DateTime(2026, 9, 12));
    });

    test('slack is the room left after the activity, not before it', () {
      // No slack means the card must not offer "you could start later".
      expect(make().hasSlack, isFalse);
      expect(
        make(
          startsAt: DateTime(2026, 9, 12, 12),
          endsAt: DateTime(2026, 9, 12, 13, 30),
          windowEndsAt: DateTime(2026, 9, 12, 17),
        ).hasSlack,
        isTrue,
      );
    });
  });

  group('DateCandidate weather', () {
    test('no forecast is unknown, not zero', () {
      // Past the forecast horizon every weather column is null. If any of
      // this defaulted to 0 the card would show "0/100" for November, which
      // is not what the ranking did and not what is true.
      final DateCandidate c = make();
      expect(c.weatherScore, isNull);
      expect(c.hasWeather, isFalse);
      expect(c.weatherIsStormy, isFalse);
    });

    test('only WMO 95/96/99 count as a storm', () {
      expect(make(weatherCode: 95).weatherIsStormy, isTrue);
      expect(make(weatherCode: 99).weatherIsStormy, isTrue);
      expect(make(weatherCode: 65).weatherIsStormy, isFalse);
      expect(make(weatherCode: 0).weatherIsStormy, isFalse);
    });

    test('warns when the activity would run past sunset', () {
      // User story D4 — "will we be descending in the dark".
      final DateTime start = DateTime(2026, 12, 6, 15);
      expect(
        make(
          startsAt: start,
          endsAt: start.add(const Duration(hours: 2)),
          sunset: DateTime(2026, 12, 6, 15, 59),
        ).endsAfterDark,
        isTrue,
      );
      expect(
        make(
          startsAt: start,
          endsAt: start.add(const Duration(minutes: 30)),
          sunset: DateTime(2026, 12, 6, 15, 59),
        ).endsAfterDark,
        isFalse,
      );
    });

    test('no sunset data means no dark warning, not a false one', () {
      expect(make().endsAfterDark, isFalse);
    });
  });

  group('ManualBusyBlock', () {
    test('a whole day sends no times at all', () {
      final Map<String, dynamic> json =
          ManualBusyBlock.allDay(DateTime(2026, 9, 4)).toJson();
      expect(json, <String, dynamic>{'day': '2026-09-04'});
    });

    test('a partial day sends zero-padded wall-clock times', () {
      final Map<String, dynamic> json = ManualBusyBlock(
        day: DateTime(2026, 9, 4),
        from: const Duration(hours: 9),
        to: const Duration(hours: 17, minutes: 30),
      ).toJson();
      expect(json['from'], '09:00');
      expect(json['to'], '17:30');
    });

    test('the date is never locale-formatted', () {
      // This is a wire format for Postgres. If it ever picks up the device
      // locale it becomes "4. 9. 2026" and the insert fails in production
      // only, on Czech phones.
      expect(
        ManualBusyBlock.allDay(DateTime(2026, 12, 31)).toJson()['day'],
        '2026-12-31',
      );
    });

    test('reads back a row from my_busy_blocks', () {
      final ManualBusyBlock b = ManualBusyBlock.fromRow(<String, dynamic>{
        'day': '2026-09-04',
        'from_time': '10:00:00',
        'to_time': '12:00:00',
        'is_all_day': false,
      });
      expect(b.isAllDay, isFalse);
      expect(b.from, const Duration(hours: 10));
      expect(b.to, const Duration(hours: 12));
    });

    test('an all-day row drops the times it was stored with', () {
      // my_busy_blocks reports 00:00-00:00 for a whole day; carrying that
      // into the editor would render "0:00–0:00" on the chip.
      final ManualBusyBlock b = ManualBusyBlock.fromRow(<String, dynamic>{
        'day': '2026-09-04',
        'from_time': '00:00:00',
        'to_time': '00:00:00',
        'is_all_day': true,
      });
      expect(b.isAllDay, isTrue);
      expect(b.from, isNull);
    });
  });
}
