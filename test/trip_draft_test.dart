import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/trips/domain/trip.dart';
import 'package:planto/features/trips/domain/trip_draft.dart';
import 'package:planto/features/trips/domain/trip_repository.dart';

import 'trip_test.dart' show make;

TripDraft filled({int durationMinutes = 1440}) {
  return TripDraft.blank()
    ..title = 'Test'
    ..originLabel = 'Praha hl.n.'
    ..originLat = 50.08
    ..originLon = 14.43
    ..windowStart = DateTime(2026, 9, 11)
    ..windowEnd = DateTime(2026, 9, 20)
    ..durationMinutes = durationMinutes;
}

void main() {
  group('validace', () {
    test('vrací důvod, ne jen zákaz', () {
      expect(TripDraft.blank().validationError, 'Doplňte název.');
      expect(
        (TripDraft.blank()..title = 'X').validationError,
        'Vyberte, odkud jedete.',
      );
      expect(filled().validationError, isNull);
    });

    test('setkání se obejde bez původu', () {
      final TripDraft m = TripDraft.blank(kind: TripKind.meeting)
        ..title = 'Sync'
        ..windowStart = DateTime(2026, 9, 11)
        ..windowEnd = DateTime(2026, 9, 20);
      expect(m.validationError, isNull);
    });

    test('výlet delší než okno nemá co nabídnout', () {
      // Okno je 11.–20. 9. včetně, tedy deset dní.
      expect(filled(durationMinutes: 10 * 1440).validationError, isNull);
      expect(filled(durationMinutes: 11 * 1440).validationError, isNotNull);
    });

    test('na hodiny se neplánuje rok dopředu', () {
      final TripDraft d = filled(durationMinutes: 120)
        ..windowEnd = DateTime(2027, 9, 11);
      expect(d.validationError, contains('42'));
    });
  });

  group('okno', () {
    test('konec se převádí tam a zpátky beze změny', () {
      // Databáze drží konec exkluzivně, picker jako poslední den. Kdyby se ta
      // konverze udělala jen jedním směrem, okno by se při každém uložení
      // posunulo o den — a nikdo by si toho hned nevšiml.
      final Trip t = make();
      final TripDraft d = TripDraft.from(t);
      expect(d.windowEnd, t.windowEnd.subtract(const Duration(days: 1)));
      expect(d.patchFrom(t).containsKey('window_end'), isFalse);
    });

    test('nedotčený formulář nevyrobí žádný patch', () {
      final Trip t = make();
      expect(TripDraft.from(t).patchFrom(t), isEmpty);
    });
  });

  group('patch', () {
    test('nese jen změněná pole', () {
      final Trip t = make();
      final TripDraft d = TripDraft.from(t)..durationMinutes = 2880;
      final Map<String, Object?> p = d.patchFrom(t);
      expect(p.keys, <String>['duration_minutes']);
      expect(p['duration_minutes'], 2880);
    });

    test('vymazání se pozná od nedotčení', () {
      // Klíč s null maže, chybějící klíč nechává být. Kdyby to byl jeden
      // případ, nešlo by rozpočet nikdy zrušit.
      final Trip t = make();
      final TripDraft d = TripDraft.from(t)..description = '  ';
      expect(d.patchFrom(t).containsKey('description'), isFalse);

      final Trip withText = make();
      final TripDraft e = TripDraft.from(withText)..budgetPerPerson = 900;
      expect(e.patchFrom(withText)['budget_per_person'], 900);
    });

    test('setkání neposílá pole, která nemá', () {
      final Trip m = make(kind: TripKind.meeting);
      final TripDraft d = TripDraft.from(m)
        ..transport = TransportPref.car
        ..budgetPerPerson = 500;
      expect(d.patchFrom(m), isEmpty);
    });
  });

  group('varování před uložením', () {
    test('zúžení okna ohlásí smazané hlasy', () {
      final Trip t = make();
      final TripDraft d = TripDraft.from(t)
        ..windowStart = DateTime(2026, 9, 13);
      expect(d.warningsAgainst(t).first, contains('mimo nové rozmezí'));
    });

    test('přeskok mezi hodinami a dny ohlásí celé hlasování', () {
      final Trip t = make();
      final TripDraft d = TripDraft.from(t)..durationMinutes = 120;
      expect(
        d.warningsAgainst(t).any((String w) => w.contains('hlasování')),
        isTrue,
      );
    });

    test('změna, která se termínů netýká, nevaruje', () {
      final Trip t = make();
      final TripDraft d = TripDraft.from(t)..budgetPerPerson = 1200;
      expect(d.warningsAgainst(t), isEmpty);
    });
  });

  test('NewTrip posílá exkluzivní konec okna', () {
    final NewTrip n = filled().toNewTrip();
    // Picker vrací půlnoc posledního dne; bez posunu by výlet na poslední den
    // okna vypadl z hledání.
    expect(n.windowEnd, DateTime(2026, 9, 21));
    expect(n.durationMinutes, 1440);
  });
}
