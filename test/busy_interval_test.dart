import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/availability/domain/busy_interval.dart';

BusyInterval at(int h1, int m1, int h2, int m2) => BusyInterval(
      start: DateTime(2026, 9, 12, h1, m1),
      end: DateTime(2026, 9, 12, h2, m2),
    );

void main() {
  final DateTime windowStart = DateTime(2026, 9, 11);
  final DateTime windowEnd = DateTime(2026, 9, 16);

  List<BusyInterval> prep(List<BusyInterval> raw) => BusyIntervals.prepare(
        raw,
        windowStart: windowStart,
        windowEnd: windowEnd,
      );

  group('BusyIntervals.prepare', () {
    test('rounds outward to 15 minutes', () {
      // 14:03–14:52 must become 14:00–15:00. Rounding inward would report the
      // user free during a meeting, which is the one error that must not happen.
      final List<BusyInterval> out = prep(<BusyInterval>[at(14, 3, 14, 52)]);
      expect(out.single.start, DateTime(2026, 9, 12, 14));
      expect(out.single.end, DateTime(2026, 9, 12, 15));
    });

    test('leaves exact quarter-hours alone', () {
      final List<BusyInterval> out = prep(<BusyInterval>[at(9, 0, 10, 30)]);
      expect(out.single.start, DateTime(2026, 9, 12, 9));
      expect(out.single.end, DateTime(2026, 9, 12, 10, 30));
    });

    test('merges overlapping blocks', () {
      final List<BusyInterval> out =
          prep(<BusyInterval>[at(9, 0, 11, 0), at(10, 0, 12, 0)]);
      expect(out, hasLength(1));
      expect(out.single.end, DateTime(2026, 9, 12, 12));
    });

    test('merges touching blocks', () {
      // Back-to-back meetings are two hours of being unavailable, and one row
      // is both smaller and truer than two.
      final List<BusyInterval> out =
          prep(<BusyInterval>[at(9, 0, 10, 0), at(10, 0, 11, 0)]);
      expect(out, hasLength(1));
    });

    test('keeps a real gap as two blocks', () {
      final List<BusyInterval> out =
          prep(<BusyInterval>[at(9, 0, 10, 0), at(13, 0, 14, 0)]);
      expect(out, hasLength(2));
    });

    test('clips to the trip window', () {
      final List<BusyInterval> out = prep(<BusyInterval>[
        BusyInterval(
          start: DateTime(2026, 8, 1),
          end: DateTime(2026, 9, 12, 10),
        ),
      ]);
      expect(out.single.start, windowStart,
          reason: 'a year of calendar history must never leave the device');
    });

    test('drops anything entirely outside the window', () {
      final List<BusyInterval> out = prep(<BusyInterval>[
        BusyInterval(
          start: DateTime(2026, 7, 1),
          end: DateTime(2026, 7, 2),
        ),
      ]);
      expect(out, isEmpty);
    });

    test('sorts unordered input', () {
      final List<BusyInterval> out =
          prep(<BusyInterval>[at(15, 0, 16, 0), at(9, 0, 10, 0)]);
      expect(out.first.start.hour, 9);
    });
  });
}
