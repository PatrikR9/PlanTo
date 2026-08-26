/// Vícedenní výlet a čas na místě jako zadání.
///
/// Obojí se ukázalo až na skutečném dvoudenním výletu: plán stavěl všechno na
/// první den, takže cesta zpět vycházela ještě týž večer. A délka pobytu byla
/// jenom odvozené číslo — nedalo se říct „chceme tam být do neděle večera"
/// a nechat spoj domů, ať se najde k tomu.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/planner/domain/journey.dart';
import 'package:planto/features/planner/domain/plan_change.dart';
import 'package:planto/features/planner/domain/plan_context.dart';
import 'package:planto/features/planner/domain/plan_item.dart';
import 'package:planto/features/planner/domain/replanner.dart';
import 'package:planto/features/planner/domain/trip_plan.dart';

import 'plan_fixtures.dart';

void main() {
  const Replanner engine = Replanner();

  SegmentResult found(Journey j) => SegmentResult(
        chosen: j,
        provider: 'transitous',
        hasTimetable: true,
      );

  TripPlan emptyPlan(PlanContext ctx) =>
      TripPlan(tripId: ctx.tripId, items: const <PlanItem>[]);

  group('vícedenní výlet', () {
    final PlanContext two = testContext(
      returnDate: DateTime(2026, 9, 13),
      dayEndLocal: DateTime(2026, 9, 13, 21, 0),
    );

    test('jednodenní výlet má den návratu shodný se dnem odjezdu', () {
      final PlanContext one = testContext();
      expect(one.returnDate, one.planDate);
      expect(one.isMultiDay, isFalse);
      expect(one.days, 1);
    });

    test('dvoudenní výlet ví, že trvá dva dny', () {
      expect(two.isMultiDay, isTrue);
      expect(two.days, 2);
    });

    test('cesta zpět se hledá na poslední den termínu', () {
      final ReplanNeeds needs =
          engine.needsFor(emptyPlan(two), const BuildPlan(), two);

      expect(needs.homeward, isNotNull);
      final JourneyQuery q = needs.homeward!.query;
      expect(
        q.arriveBy,
        isTrue,
        reason: 'bez vlastního zadání se návrat hledá podle konce dne',
      );
      expect(
        two.wallClock(q.when),
        DateTime(2026, 9, 13, 21, 0),
        reason: 'večer druhého dne, ne prvního — to byla ta chyba',
      );
    });

    test('cesta tam se hledá pořád na první den', () {
      final ReplanNeeds needs =
          engine.needsFor(emptyPlan(two), const BuildPlan(), two);

      expect(two.wallClock(needs.outbound!.query.when), wall(7, 0));
    });
  });

  group('čas na místě', () {
    final PlanContext ctx = testContext();

    test('„vyrazíme v pět" hledá odjezd, ne příjezd domů', () {
      final ReplanNeeds needs = engine.needsFor(
        emptyPlan(ctx),
        SetLeaveAt(wall(17, 0)),
        ctx,
      );

      final JourneyQuery q = needs.homeward!.query;
      expect(
        q.arriveBy,
        isFalse,
        reason: 'je to čas odjezdu z cíle, ne deadline doma',
      );
      expect(ctx.wallClock(q.when), wall(17, 0));
      expect(
        q.direction,
        PlanSegment.homeward,
        reason: 'cesta zpět je vlastní hledání, ne obrácená cesta tam',
      );
    });

    test('cesta tam se tím nepřepočítává', () {
      final ReplanNeeds needs = engine.needsFor(
        emptyPlan(ctx),
        SetLeaveAt(wall(17, 0)),
        ctx,
      );
      expect(needs.outbound, isNull);
    });

    test('nastavení odjezdu ruší „být doma do" a naopak', () {
      final TripPlan withDeadline = engine
          .apply(
            emptyPlan(ctx),
            SetHomeBy(wall(20, 0)),
            ctx,
            homeward: found(homewardJourney()),
          )
          .plan;
      expect(withDeadline.homeBy, isNotNull);
      expect(withDeadline.leaveAt, isNull);

      final TripPlan withLeave = engine
          .apply(
            withDeadline,
            SetLeaveAt(wall(17, 0)),
            ctx,
            homeward: found(homewardJourney()),
          )
          .plan;
      expect(
        withLeave.homeBy,
        isNull,
        reason: 'dvě odpovědi na tutéž otázku znamenají, že se jedna ignoruje',
      );
      expect(withLeave.leaveAt, ctx.instant(wall(17, 0)));

      final TripPlan backToDeadline = engine
          .apply(
            withLeave,
            SetHomeBy(wall(21, 0)),
            ctx,
            homeward: found(homewardJourney()),
          )
          .plan;
      expect(backToDeadline.leaveAt, isNull);
      expect(backToDeadline.homeBy, ctx.instant(wall(21, 0)));
    });

    test('zadání přežije uložení a načtení', () {
      final TripPlan p = engine
          .apply(
            emptyPlan(ctx),
            SetLeaveAt(wall(17, 0)),
            ctx,
            homeward: found(homewardJourney()),
          )
          .plan;

      final Map<String, dynamic> wire = p.toWire();
      expect(wire['leave_at'], isNotNull);

      final TripPlan back = TripPlan.fromWire(ctx.tripId, <String, dynamic>{
        ...wire,
        'items': const <dynamic>[],
      });
      expect(back.leaveAt, p.leaveAt);
    });

    test('posun odjezdu se sám nevrátí — ustoupí program, ne spoj', () {
      // Automaticky vyplněný program sahá od příjezdu po odjezd. Když se
      // odjezd posune dopředu, program ho v témže přepočtu přeroste — a
      // druhé kolo by se vydalo hledat spoj až po konci programu, tedy
      // zhruba tam, odkud se odjezd zrovna posouval. Zvenčí to vypadalo, že
      // se s časem odjezdu nedá hnout.
      final TripPlan built = engine
          .apply(
            emptyPlan(ctx),
            const BuildPlan(),
            ctx,
            outbound: found(outboundJourney()),
            homeward: found(homewardJourney()),
          )
          .plan;
      expect(
        built.segment(PlanSegment.stay),
        isNotEmpty,
        reason: 'engine vyplní pobyt jedním blokem programu',
      );

      final ReplanOutcome moved = engine.apply(
        built,
        SetLeaveAt(wall(15, 30)),
        ctx,
        homeward: found(earlyHomewardJourney()),
      );

      expect(
        moved.followUp.homeward,
        isNull,
        reason: 'zadaný odjezd se nesmí přehledat zpátky na pozdější spoj',
      );
      expect(moved.plan.departureHome, ctx.instant(wall(15, 30)));

      final PlanItem program = moved.plan.segment(PlanSegment.stay).last;
      expect(
        program.localEnd.isBefore(wall(15, 30)),
        isTrue,
        reason: 'zkrátit program je menší změna než přehodit spoj',
      );
    });

    test('bez zadání smí program odjezd naopak odsunout', () {
      final TripPlan built = engine
          .apply(
            emptyPlan(ctx),
            const BuildPlan(),
            ctx,
            outbound: found(outboundJourney()),
            homeward: found(homewardJourney()),
          )
          .plan;

      final PlanItem program = built.segment(PlanSegment.stay).single;
      final ReplanOutcome stretched = engine.apply(
        built,
        ResizeItem(program.id, const Duration(hours: 9)),
        ctx,
      );

      expect(
        stretched.followUp.homeward,
        isNotNull,
        reason: 'spoj, který vybral engine, se kvůli programu vyměnit smí',
      );
    });

    test('délka pobytu je od příjezdu po odjezd, ne po návrat domů', () {
      final TripPlan p = engine
          .apply(
            emptyPlan(ctx),
            const BuildPlan(),
            ctx,
            outbound: found(outboundJourney()),
            homeward: found(homewardJourney()),
          )
          .plan;

      final DateTime arrival = p.arrivalAtDestination!;
      final DateTime departure = p.departureHome!;
      expect(p.stayLength, departure.difference(arrival));
      expect(
        p.stayLength!.inMinutes < p.arrivalHome!.difference(arrival).inMinutes,
        isTrue,
        reason: 'cesta domů není čas strávený v cíli',
      );
    });
  });
}
