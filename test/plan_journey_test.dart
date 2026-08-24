import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/planner/domain/journey.dart';
import 'package:planto/features/planner/domain/plan_item.dart';

import 'plan_fixtures.dart';

/// Parsování odpovědi vyhledávače spojení.
///
/// Testuje se **náš** tvar, ne tvar Transitousu: klient odpověď poskytovatele
/// nikdy nevidí, normalizace je v Edge Function a má vlastní testy
/// (`supabase/functions/_shared/transport_test.ts`). Tohle je druhá polovina
/// téže hranice — kdyby se rozešly, projeví se to tady.
void main() {
  group('Journey.fromWire', () {
    test('trasa s přestupem se přeloží se vším, co osa potřebuje', () {
      final Journey j = Journey.fromWire(outboundWire());

      expect(j.legs.length, 3);
      expect(j.transfers, 1, reason: 'vlak → autobus je jeden přestup');
      expect(j.walkMinutes, 15);
      expect(j.durationMinutes, 162, reason: '08:10 → 10:52 je 2 h 42 min');
      expect(j.isDirect, isFalse);

      final JourneyLeg train = j.legs[1];
      expect(train.mode, TransitMode.train);
      expect(train.lineName, 'R 640');
      expect(train.operatorName, 'České dráhy');
      expect(train.platform, '3');
      expect(train.fromName, 'Praha hl.n.');
      expect(train.durationMinutes, 82);
      expect(train.intermediateStopNames, <String>['Tábor']);
    });

    test('místní časy jsou nástěnné hodiny výletu, ne zóna telefonu', () {
      final Journey j = Journey.fromWire(outboundWire());
      // Instant je 06:10Z, místní čas 08:10. Kdyby se počítal z `toLocal()`,
      // vyšlo by na emulátoru v UTC 06:10 — přesně chyba, kterou opravovala
      // migrace 20260821140000.
      expect(j.departure.toUtc().hour, 6);
      expect(j.localDeparture.hour, 8);
      expect(j.localDeparture.minute, 10);
      expect(j.localArrival.hour, 10);
      expect(j.localArrival.minute, 52);
    });

    test('trasa bez přestupu má nula přestupů a jeden úsek jízdy', () {
      final Journey j = Journey.fromWire(directWire());
      expect(j.transfers, 0);
      expect(j.isDirect, isTrue);
      expect(j.transitLegs.length, 1);
      expect(j.transferWaits, isEmpty);
    });

    test('čekání na přestupech se počítá z časů, nepřenáší se', () {
      final Journey j = Journey.fromWire(outboundWire());
      expect(j.transferWaits.length, 1);
      expect(j.transferWaits.first.inMinutes, 14);
    });

    test('pěší úsek je poznat a nepočítá se jako přestup', () {
      final Journey j = Journey.fromWire(outboundWire());
      expect(j.legs.first.isWalk, isTrue);
      expect(j.legs.first.mode, TransitMode.walk);
      expect(j.transfers, 1);
    });

    test('jízdné je vždycky rozpětí a vždycky odhad', () {
      final Journey j = Journey.fromWire(outboundWire());
      final FareEstimate fare = j.fare!;
      expect(fare.isEstimate, isTrue);
      expect(fare.min, lessThan(fare.max));
      expect(fare.confidence, FareConfidence.medium);
      expect(fare.basis, isNotEmpty,
          reason: 'odhad, který nejde rozebrat, nejde ani opravit');
    });

    test('zpoždění se pozná z rozdílu proti jízdnímu řádu', () {
      final Journey j = Journey.fromWire(outboundWire());
      // Plán 09:45, skutečnost 09:47.
      expect(j.legs[1].delayMinutes, 2);
      // Bez realtime dat je zpoždění null, ne nula: „nevíme" a „jede včas"
      // nejsou totéž.
      expect(j.legs[2].delayMinutes, isNull);
    });
  });

  group('JourneySearch.fromWire', () {
    test('žádná nalezená trasa je prázdný výsledek, ne chyba', () {
      final JourneySearch s = JourneySearch.fromWire(<String, dynamic>{
        'provider': 'transitous',
        'has_timetable': true,
        'options': <dynamic>[],
        'picks': <String, dynamic>{'best': null},
      });
      expect(s.isEmpty, isTrue);
      expect(s.best, isNull);
      expect(s.hasTimetable, isTrue,
          reason: 'vyhledávač odpověděl — jen nic nenašel');
    });

    test('výpadek poskytovatele se pozná od prázdného výsledku', () {
      final JourneySearch s = JourneySearch.fromWire(<String, dynamic>{
        'provider': 'estimate',
        'has_timetable': false,
        'provider_error': 'transitous 503',
        'options': <dynamic>[],
        'picks': <String, dynamic>{'best': null},
      });
      expect(s.providerError, 'transitous 503');
      expect(s.hasTimetable, isFalse);
    });

    test('atribuce zdrojů se nese s odpovědí', () {
      final JourneySearch s = JourneySearch.fromWire(<String, dynamic>{
        'provider': 'transitous',
        'has_timetable': true,
        'attribution': 'Spojení: Transitous · data OpenStreetMap',
        'options': <dynamic>[outboundWire()],
        'picks': <String, dynamic>{'best': 'out-1'},
      });
      expect(s.attribution, contains('Transitous'));
      expect(s.best?.id, 'out-1');
    });

    test('poškozená odpověď nevyhodí výjimku', () {
      final JourneySearch s =
          JourneySearch.fromWire(<String, dynamic>{'provider': 'estimate'});
      expect(s.isEmpty, isTrue);
    });
  });

  group('převod zóny', () {
    test('okamžik a nástěnné hodiny se převádějí tam i zpět', () {
      const Duration off = Duration(hours: 2);
      final DateTime wall = DateTime(2026, 9, 12, 8, 25);
      final DateTime instant = PlanItem.instantOf(wall, off);
      expect(instant.toUtc().hour, 6);
      expect(instant.toUtc().minute, 25);
      expect(PlanItem.wallClockOf(instant, off), wall);
    });

    test('posun zóny se odvodí z dvojice, kterou posílá server', () {
      final DateTime wall = DateTime(2026, 9, 12, 8, 25);
      final DateTime instant = DateTime.utc(2026, 9, 12, 6, 25);
      expect(PlanItem.offsetBetween(wall, instant), const Duration(hours: 2));
    });
  });
}
