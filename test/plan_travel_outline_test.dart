/// Skládání cesty do řádků, které vypadají jako vyhledaný spoj.
///
/// Testuje se tu jediná věc, a je to ta, na které se to rozbije: kdy vznikne
/// nový řádek zastávky a kdy se jenom doplní odjezd do toho, co tam už je.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/planner/domain/plan_item.dart';
import 'package:planto/features/planner/domain/travel_outline.dart';

import 'plan_fixtures.dart';

int _n = 0;

PlanItem ride({
  required String from,
  required String to,
  required int depH,
  required int depM,
  required int arrH,
  required int arrM,
  String? line,
  String? platform,
}) =>
    PlanItem.atLocal(
      id: 'ride-${_n++}',
      kind: PlanItemKind.transport,
      segment: PlanSegment.outbound,
      localStart: wall(depH, depM),
      localEnd: wall(arrH, arrM),
      zoneOffset: kTestOffset,
      titleKey: 'plan.ride',
      titleParams: <String, String>{
        'from': from,
        'to': to,
        if (line != null) 'line': line,
      },
      detail: <String, dynamic>{if (platform != null) 'platform': platform},
      fromName: from,
      toName: to,
    );

PlanItem walk({
  required int depH,
  required int depM,
  required int arrH,
  required int arrM,
  String titleKey = 'plan.walk',
  String? from,
  String? to,
}) =>
    PlanItem.atLocal(
      id: 'walk-${_n++}',
      kind: PlanItemKind.walk,
      segment: PlanSegment.outbound,
      localStart: wall(depH, depM),
      localEnd: wall(arrH, arrM),
      zoneOffset: kTestOffset,
      titleKey: titleKey,
      fromName: from,
      toName: to,
    );

PlanItem transfer({
  required String stop,
  required int depH,
  required int depM,
  required int arrH,
  required int arrM,
}) =>
    PlanItem.atLocal(
      id: 'transfer-${_n++}',
      kind: PlanItemKind.transfer,
      segment: PlanSegment.outbound,
      localStart: wall(depH, depM),
      localEnd: wall(arrH, arrM),
      zoneOffset: kTestOffset,
      titleKey: 'plan.transfer',
      fromName: stop,
      toName: stop,
    );

void main() {
  group('skládání cesty', () {
    test('prázdný úsek nevyrobí žádný řádek', () {
      expect(outlineFor(const <PlanItem>[]).isEmpty, isTrue);
    });

    test('jedna jízda jsou dvě zastávky a mezi nimi spoj', () {
      final TravelOutline o = outlineFor(<PlanItem>[
        ride(
          from: 'Praha hl.n.',
          to: 'Trutnov hl.n.',
          depH: 7,
          depM: 15,
          arrH: 9,
          arrM: 2,
          line: 'R 990',
          platform: '3',
        ),
      ]);

      expect(o.rows.length, 3);
      expect(o.rides, 1);
      expect(o.transfers, 0);

      final StopRow first = o.rows.first as StopRow;
      expect(first.name, 'Praha hl.n.');
      expect(first.departure, wall(7, 15));
      expect(first.arrival, isNull);
      expect(first.platform, '3');

      expect(o.rows[1], isA<RideRow>());

      final StopRow last = o.rows.last as StopRow;
      expect(last.name, 'Trutnov hl.n.');
      expect(last.arrival, wall(9, 2));
      expect(last.departure, isNull);
    });

    test('přestup na téže zastávce je jeden řádek se dvěma časy', () {
      final TravelOutline o = outlineFor(<PlanItem>[
        ride(
          from: 'Praha hl.n.',
          to: 'Trutnov hl.n.',
          depH: 7,
          depM: 15,
          arrH: 9,
          arrM: 2,
        ),
        transfer(stop: 'Trutnov hl.n.', depH: 9, depM: 2, arrH: 9, arrM: 8),
        ride(
          from: 'Trutnov hl.n.',
          to: 'Špindlerův Mlýn',
          depH: 9,
          depM: 8,
          arrH: 9,
          arrM: 42,
        ),
      ]);

      // Zastávka, spoj, přestupní zastávka, spoj, zastávka. Žádný řádek
      // „Přestup" — dva časy v jednom řádku jsou celý ten náznak.
      expect(o.rows.length, 5);
      expect(o.rows.whereType<LinkRow>(), isEmpty);
      expect(o.rides, 2);
      expect(o.transfers, 1);

      final StopRow middle = o.rows[2] as StopRow;
      expect(middle.name, 'Trutnov hl.n.');
      expect(middle.arrival, wall(9, 2));
      expect(middle.departure, wall(9, 8));
    });

    test('pěší přechod mezi zastávkami je text, ne bod', () {
      final TravelOutline o = outlineFor(<PlanItem>[
        ride(
          from: 'Praha hl.n.',
          to: 'Trutnov hl.n.',
          depH: 7,
          depM: 15,
          arrH: 9,
          arrM: 2,
        ),
        walk(depH: 9, depM: 2, arrH: 9, arrM: 6),
        ride(
          from: 'Trutnov, aut. nádr.',
          to: 'Špindlerův Mlýn',
          depH: 9,
          depM: 8,
          arrH: 9,
          arrM: 42,
        ),
      ]);

      final List<LinkRow> links = o.rows.whereType<LinkRow>().toList();
      expect(links.length, 1);
      expect(links.single.text, contains('pěšky 4 min'));
      expect(o.walkMinutes, 4);

      // Zastávky zůstaly dvě různé — sloučit se smí jen stejné jméno.
      expect(
        o.rows.whereType<StopRow>().map((StopRow s) => s.name).toList(),
        <String>[
          'Praha hl.n.',
          'Trutnov hl.n.',
          'Trutnov, aut. nádr.',
          'Špindlerův Mlýn',
        ],
      );
    });

    test('odchod z domova a dojití domů mají vlastní krajní zastávku', () {
      final TravelOutline o = outlineFor(<PlanItem>[
        walk(
          depH: 7,
          depM: 3,
          arrH: 7,
          arrM: 15,
          titleKey: 'plan.leave_home',
          to: 'Praha hl.n.',
        ),
        ride(
          from: 'Praha hl.n.',
          to: 'Trutnov hl.n.',
          depH: 7,
          depM: 15,
          arrH: 9,
          arrM: 2,
        ),
        walk(
          depH: 9,
          depM: 2,
          arrH: 9,
          arrM: 14,
          titleKey: 'plan.walk_home',
          from: 'Trutnov hl.n.',
        ),
      ]);

      final List<StopRow> stops = o.rows.whereType<StopRow>().toList();
      expect(stops.first.name, 'Odchod z domova');
      expect(stops.first.departure, wall(7, 3));
      expect(stops.last.name, 'Doma');
      expect(stops.last.arrival, wall(9, 14));

      expect(o.localStart, wall(7, 3));
      expect(o.localEnd, wall(9, 14));
      expect(o.walkMinutes, 24);
    });

    test('jízdné se sečte a nese měnu položky', () {
      final PlanItem paid = ride(
        from: 'Praha hl.n.',
        to: 'Trutnov hl.n.',
        depH: 7,
        depM: 15,
        arrH: 9,
        arrM: 2,
      ).copyWith(costMin: 180, costMax: 240);

      final TravelOutline o = outlineFor(<PlanItem>[paid]);
      expect(o.costMin, 180);
      expect(o.costMax, 240);
      expect(o.currency, 'CZK');
    });

    test('program na místě do cesty nepatří a nic nepokazí', () {
      final TravelOutline o = outlineFor(<PlanItem>[
        ride(
          from: 'Praha hl.n.',
          to: 'Trutnov hl.n.',
          depH: 7,
          depM: 15,
          arrH: 9,
          arrM: 2,
        ),
        PlanItem.atLocal(
          id: 'act-1',
          kind: PlanItemKind.activity,
          segment: PlanSegment.stay,
          localStart: wall(10, 0),
          localEnd: wall(12, 0),
          zoneOffset: kTestOffset,
          titleKey: 'plan.activity_default',
        ),
      ]);

      expect(o.rides, 1);
      expect(o.rows.whereType<StopRow>().length, 2);
    });
  });
}
