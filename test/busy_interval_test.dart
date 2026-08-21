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

  group('BusyIntervals.allDayToLocalMidnight', () {
    // Android ukládá celodenní událost jako UTC půlnoc — je to datum, ne
    // okamžik. Čtené jako obyčejný timestamp se v Praze v létě posune na 02:00
    // a „celý den 12. září" se uloží jako 12. 9. 02:00 – 13. 9. 02:00. Ta dvě
    // hodiny jsou u třídenního výletu neviditelné a u dvouhodinové schůzky
    // rozhodují.
    test('z UTC půlnoci udělá místní půlnoc téhož dne', () {
      final DateTime fromDevice = DateTime.fromMillisecondsSinceEpoch(
        DateTime.utc(2026, 9, 12).millisecondsSinceEpoch,
      );

      final DateTime out = BusyIntervals.allDayToLocalMidnight(fromDevice);

      expect(out, DateTime(2026, 9, 12));
      expect(out.hour, 0, reason: 'nesmí zůstat posunuté o offset zóny');
      expect(
        out.isUtc,
        isFalse,
        reason: 'zbytek řetězce počítá v místním čase',
      );
    });

    test('nezávisí na zóně, ve které test běží', () {
      // Datum se čte z UTC složek, takže výsledek je stejný v Praze i v Denveru.
      // Kdyby se četlo z místních, půlnoc UTC by v západní polokouli spadla na
      // předchozí den a celodenní blok by zabral špatné datum.
      final DateTime out = BusyIntervals.allDayToLocalMidnight(
        DateTime.utc(2026, 1, 1),
      );
      expect(out.year, 2026);
      expect(out.month, 1);
      expect(out.day, 1);
    });
  });

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
      expect(
        out.single.start,
        windowStart,
        reason: 'a year of calendar history must never leave the device',
      );
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
