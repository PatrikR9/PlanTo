import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/planner/domain/journey.dart';
import 'package:planto/features/planner/domain/plan_change.dart';
import 'package:planto/features/planner/domain/plan_context.dart';
import 'package:planto/features/planner/domain/plan_item.dart';
import 'package:planto/features/planner/domain/plan_problem.dart';
import 'package:planto/features/planner/domain/replanner.dart';
import 'package:planto/features/planner/domain/trip_plan.dart';

import 'plan_fixtures.dart';

/// Interaktivní plán a jeho přepočet.
///
/// Engine je čistá funkce, takže se dá otestovat celý — včetně pravidel,
/// která jinak jdou ověřit jenom klikáním: „zamčený bod se nehne",
/// „ručně vybraný spoj se nevymění potichu", „přepočítá se jen to, co se
/// změnou souvisí".
void main() {
  const Replanner engine = Replanner();
  final PlanContext ctx = testContext();

  SegmentResult found(Journey j) => SegmentResult(
        chosen: j,
        provider: 'transitous',
        hasTimetable: true,
      );

  TripPlan buildPlan() => engine
      .apply(
        TripPlan(tripId: ctx.tripId, items: const <PlanItem>[]),
        const BuildPlan(),
        ctx,
        outbound: found(outboundJourney()),
        homeward: found(homewardJourney()),
      )
      .plan;

  PlanItem activityOf(TripPlan p) =>
      p.items.firstWhere((PlanItem i) => i.kind == PlanItemKind.activity);

  // -------------------------------------------------------------------------
  group('sestavení plánu', () {
    test('z obou cest a programu vznikne jedna chronologická osa', () {
      final TripPlan p = buildPlan();

      expect(p.items.length, 9);
      expect(p.segment(PlanSegment.outbound).length, 4,
          reason: 'chůze, vlak, přestup, autobus');
      expect(p.segment(PlanSegment.stay).length, 1);
      expect(p.segment(PlanSegment.homeward).length, 4,
          reason: 'autobus, přestup, vlak, chůze domů');

      // Chronologicky a bez děr v pořadí.
      for (int i = 1; i < p.items.length; i++) {
        expect(
          p.items[i].startsAt.isBefore(p.items[i - 1].startsAt),
          isFalse,
          reason: 'osa musí být seřazená',
        );
      }

      expect(p.items.first.localStart, wall(8, 10));
      expect(p.items.last.localEnd, wall(20, 5),
          reason: 'po posledním vlaku ještě deset minut domů');
      expect(p.hasTimetable, isTrue);
      expect(p.planDate, DateTime(2026, 9, 12));
    });

    test('přestup je vlastní položka s délkou čekání', () {
      final TripPlan p = buildPlan();
      final PlanItem transfer = p
          .segment(PlanSegment.outbound)
          .firstWhere((PlanItem i) => i.kind == PlanItemKind.transfer);
      expect(transfer.localStart, wall(9, 47));
      expect(transfer.localEnd, wall(10, 1));
      expect(transfer.duration, const Duration(minutes: 14));
      expect(transfer.titleParams['stop'], 'České Budějovice');
    });

    test('program vyplní čas mezi příjezdem a odjezdem zpět', () {
      final PlanItem activity = activityOf(buildPlan());
      expect(activity.localStart, wall(11, 7),
          reason: 'příjezd 10:52 plus čtvrthodina na rozkoukání');
      expect(activity.localEnd, wall(16, 55),
          reason: 'deset minut před odjezdem v 17:05');
      expect(activity.isLocked, isFalse);
      expect(activity.source, PlanItemSource.generated);
    });

    test('jízdné visí na spoji a je označené jako odhad', () {
      final TripPlan p = buildPlan();
      final PlanItem ride = p
          .segment(PlanSegment.outbound)
          .firstWhere((PlanItem i) => i.kind == PlanItemKind.transport);
      expect(ride.costMin, 240);
      expect(ride.costMax, 320);
      expect(ride.confidence, PlanConfidence.estimated);
      expect(ride.detail['fare_covers'], 'journey');
    });

    test('bez jízdního řádu to plán řekne nahlas', () {
      final TripPlan p = engine
          .apply(
            TripPlan(tripId: ctx.tripId, items: const <PlanItem>[]),
            const BuildPlan(),
            ctx,
            outbound: SegmentResult(
              chosen: outboundJourney(),
              provider: 'estimate',
            ),
            homeward: SegmentResult(
              chosen: homewardJourney(),
              provider: 'estimate',
            ),
          )
          .plan;
      expect(p.hasTimetable, isFalse);
      expect(
        p.warnings.map((PlanProblem w) => w.code),
        contains(PlanProblemCode.noTimetable),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('co se kvůli změně hledá znovu', () {
    test('cesta tam a cesta zpět jsou dva samostatné dotazy', () {
      final ReplanNeeds needs = engine.needsFor(
        TripPlan(tripId: ctx.tripId, items: const <PlanItem>[]),
        const BuildPlan(),
        ctx,
      );

      final JourneyQuery out = needs.outbound!.query;
      final JourneyQuery home = needs.homeward!.query;

      expect(out.origin.name, 'Praha hl.n.');
      expect(out.destination.name, 'Český Krumlov');
      expect(home.origin.name, 'Český Krumlov',
          reason: 'zpáteční cesta se hledá z cíle, není to obrácený itinerář');
      expect(home.destination.name, 'Praha hl.n.');
      expect(out.arriveBy, isFalse);
      expect(home.arriveBy, isTrue);
      expect(out.when, isNot(home.when));
      expect(out, isNot(home));
    });

    test('požadavek na příjezd hýbe jenom cestou tam', () {
      final ReplanNeeds needs =
          engine.needsFor(buildPlan(), SetArriveBy(wall(12, 0)), ctx);
      expect(needs.outbound, isNotNull);
      expect(needs.homeward, isNull,
          reason: 'cesta zpět s tím nemá co dělat');
      expect(needs.outbound!.query.arriveBy, isTrue);
      expect(needs.outbound!.query.when, ctx.instant(wall(12, 0)));
    });

    test('deadline návratu hýbe jenom cestou zpět', () {
      final ReplanNeeds needs =
          engine.needsFor(buildPlan(), SetHomeBy(wall(20, 0)), ctx);
      expect(needs.homeward, isNotNull);
      expect(needs.outbound, isNull);
      expect(needs.homeward!.query.arriveBy, isTrue);
      expect(needs.homeward!.query.when, ctx.instant(wall(20, 0)));
    });

    test('posun aktivity nehledá nic, dokud se vejde do plánu', () {
      final TripPlan p = buildPlan();
      final ReplanNeeds needs = engine.needsFor(
        p,
        EditItem(activityOf(p).id, duration: const Duration(hours: 2)),
        ctx,
      );
      expect(needs.isEmpty, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('zamčené a flexibilní položky', () {
    test('flexibilní program se posune za pozdější příjezd', () {
      final TripPlan p = buildPlan();
      final ReplanOutcome r = engine.apply(
        p,
        SetArriveBy(wall(14, 0)),
        ctx,
        outbound: found(lateOutboundJourney()),
      );

      final PlanItem activity = activityOf(r.plan);
      expect(activity.localStart, wall(14, 45),
          reason: 'příjezd 14:30 plus čtvrthodina');
      expect(r.changedIds, contains(activity.id));
    });

    test('zamčený program se nehne a aplikace to řekne', () {
      TripPlan p = buildPlan();
      final PlanItem activity = activityOf(p);

      p = engine
          .apply(
            p,
            EditItem(
              activity.id,
              localStart: wall(13, 0),
              duration: const Duration(hours: 1),
              locked: true,
            ),
            ctx,
          )
          .plan;
      expect(activityOf(p).isLocked, isTrue);
      expect(activityOf(p).localStart, wall(13, 0));

      final ReplanOutcome r = engine.apply(
        p,
        SetArriveBy(wall(14, 0)),
        ctx,
        outbound: found(lateOutboundJourney()),
      );

      final PlanItem after = activityOf(r.plan);
      expect(after.localStart, wall(13, 0),
          reason: 'zamčený bod se nesmí tiše posunout');
      expect(r.changedIds, isNot(contains(after.id)));
      expect(
        r.problems.map((PlanProblem e) => e.code),
        contains(PlanProblemCode.arrivalAfterActivity),
      );
    });

    test('ruční úprava se pozná i po dalším přepočtu', () {
      TripPlan p = buildPlan();
      p = engine
          .apply(
            p,
            EditItem(activityOf(p).id, duration: const Duration(hours: 3)),
            ctx,
          )
          .plan;
      expect(activityOf(p).userEdited, isTrue);
      expect(activityOf(p).duration, const Duration(hours: 3));
    });

    test('zamknout a odemknout jde bez ztráty ostatního stavu', () {
      TripPlan p = buildPlan();
      final String id = activityOf(p).id;
      p = engine.apply(p, SetItemLocked(id, locked: true), ctx).plan;
      expect(activityOf(p).isLocked, isTrue);
      p = engine.apply(p, SetItemLocked(id, locked: false), ctx).plan;
      expect(activityOf(p).isLocked, isFalse);
      expect(p.items.length, 9, reason: 'zámek nic nemaže');
    });
  });

  // -------------------------------------------------------------------------
  group('minimální nutná změna', () {
    test('prodloužení programu si vyžádá jenom nový spoj domů', () {
      final TripPlan p = buildPlan();
      final List<String> outboundIds = p
          .segment(PlanSegment.outbound)
          .map((PlanItem i) => i.id)
          .toList();

      final ReplanOutcome r = engine.apply(
        p,
        EditItem(activityOf(p).id, duration: const Duration(hours: 8)),
        ctx,
      );

      expect(r.followUp.homeward, isNotNull);
      expect(r.followUp.outbound, isNull,
          reason: 'cesta tam se prodloužením programu nemění');
      expect(
        r.plan.segment(PlanSegment.outbound).map((PlanItem i) => i.id).toList(),
        outboundIds,
        reason: 'cesta tam zůstala beze změny, včetně ID položek',
      );
      // Druhé kolo hledá odjezd až po konci programu.
      expect(r.followUp.homeward!.query.arriveBy, isFalse);
      expect(r.followUp.homeward!.intent, SegmentIntent.cascade);
    });

    test('zamčený návrat se nevymění — zkrátí se program', () {
      TripPlan p = buildPlan();
      p = engine
          .apply(
            p,
            ChooseJourney(PlanSegment.homeward, earlyHomewardJourney()),
            ctx,
          )
          .plan;

      final PlanItem activity = activityOf(p);
      expect(activity.localEnd, wall(15, 20),
          reason: 'návrat v 15:30 minus deset minut na zastávku');
      expect(
        p.segment(PlanSegment.homeward).first.source,
        PlanItemSource.userSelected,
      );
    });

    test('přepočet zachová maximum původního plánu', () {
      TripPlan p = buildPlan();
      final PlanItem custom = PlanItem.atLocal(
        id: newPlanItemId(),
        kind: PlanItemKind.meal,
        segment: PlanSegment.stay,
        localStart: wall(12, 0),
        localEnd: wall(13, 0),
        zoneOffset: kTestOffset,
        titleKey: kNamedItemKey,
        titleParams: const <String, String>{'title': 'Oběd'},
        source: PlanItemSource.userCreated,
      );
      p = engine.apply(p, AddItem(custom), ctx).plan;
      expect(p.items.length, 10);

      final ReplanOutcome r = engine.apply(
        p,
        SetHomeBy(wall(20, 0)),
        ctx,
        homeward: found(homewardJourney()),
      );

      expect(
        r.plan.items.any((PlanItem i) => i.id == custom.id),
        isTrue,
        reason: 'vlastní bod přepočet nesmaže',
      );
      expect(
        r.plan.segment(PlanSegment.outbound).length,
        4,
        reason: 'cesta tam se deadlinem návratu nemění',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('ručně vybraný spoj', () {
    JourneyQuery homewardQuery() => JourneyQuery(
          origin: ctx.destination,
          destination: ctx.origin,
          when: ctx.instant(wall(20, 0)),
          arriveBy: true,
          direction: PlanSegment.homeward,
        );

    test('nevymění se kvůli něčemu, o co uživatel nežádal', () {
      TripPlan p = buildPlan();
      p = engine
          .apply(
            p,
            ChooseJourney(PlanSegment.homeward, earlyHomewardJourney()),
            ctx,
          )
          .plan;

      final ReplanOutcome r = engine.apply(
        p,
        const NoChange(),
        ctx,
        needs: ReplanNeeds(
          homeward: SegmentNeed(homewardQuery(), SegmentIntent.cascade),
        ),
        homeward: found(lateHomewardJourney()),
      );

      expect(
        r.plan
            .segment(PlanSegment.homeward)
            .any((PlanItem i) => i.titleParams['line'] == 'R 643'),
        isTrue,
        reason: 'vybraný spoj musí zůstat',
      );
      expect(
        r.problems.map((PlanProblem e) => e.code),
        contains(PlanProblemCode.lockedConflict),
      );
    });

    test('když ho nové zadání vyloučí, vymění se — a řekne se to', () {
      TripPlan p = buildPlan();
      p = engine
          .apply(
            p,
            ChooseJourney(PlanSegment.homeward, earlyHomewardJourney()),
            ctx,
          )
          .plan;

      final ReplanOutcome r = engine.apply(
        p,
        SetHomeBy(wall(21, 0)),
        ctx,
        homeward: found(lateHomewardJourney()),
      );

      expect(
        r.plan
            .segment(PlanSegment.homeward)
            .any((PlanItem i) => i.titleParams['line'] == 'R 645'),
        isTrue,
      );
      expect(
        r.problems.map((PlanProblem e) => e.code),
        contains(PlanProblemCode.userChoiceReplaced),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('když to nejde', () {
    test('nenalezený návrat nabídne nejbližší možný čas', () {
      final ReplanOutcome r = engine.apply(
        buildPlan(),
        SetHomeBy(wall(20, 0)),
        ctx,
        homeward: SegmentResult(
          nearestMiss: lateHomewardJourney(),
          provider: 'transitous',
          hasTimetable: true,
        ),
      );

      final PlanProblem problem = r.problems
          .firstWhere((PlanProblem e) => e.code == PlanProblemCode.noReturnFound);
      expect(problem.params['earliest'], contains('20:42'));
      expect(problem.isBlocking, isTrue);
      // Původní cesta zpět zůstala — plán bez návratu je horší než návrat,
      // který nesplňuje nové přání.
      expect(r.plan.segment(PlanSegment.homeward), isNotEmpty);
    });

    test('nenalezená cesta tam plán nesmaže', () {
      final ReplanOutcome r = engine.apply(
        buildPlan(),
        SetArriveBy(wall(9, 0)),
        ctx,
        outbound: const SegmentResult(provider: 'transitous', hasTimetable: true),
      );
      expect(
        r.problems.map((PlanProblem e) => e.code),
        contains(PlanProblemCode.noOutboundFound),
      );
      expect(r.plan.segment(PlanSegment.outbound).length, 4);
    });

    test('pozdější příjezd, než uživatel chtěl, je taky informace', () {
      final ReplanOutcome r = engine.apply(
        buildPlan(),
        SetArriveBy(wall(12, 0)),
        ctx,
        outbound: found(lateOutboundJourney()),
      );
      expect(
        r.problems.map((PlanProblem e) => e.code),
        contains(PlanProblemCode.arrivalAfterRequest),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('persistence', () {
    test('stav položky přežije uložení i načtení', () {
      TripPlan p = buildPlan();
      final String id = activityOf(p).id;
      p = engine
          .apply(
            p,
            EditItem(
              id,
              localStart: wall(12, 0),
              duration: const Duration(hours: 2),
              title: 'Prohlídka hradu',
              locked: true,
            ),
            ctx,
          )
          .plan;

      // Kolečko přes server: klient pošle toWire, server dopíše ID a místní
      // časy, klient to načte zpátky.
      final Map<String, dynamic> wire = p.toWire();
      final List<Map<String, dynamic>> items =
          (wire['items']! as List<dynamic>).cast<Map<String, dynamic>>();
      final Map<String, dynamic> stored = <String, dynamic>{
        'id': 'srv-plan',
        'variant': 'primary',
        'plan_date': wire['plan_date'],
        'depart_after': wire['depart_after'],
        'arrive_by': wire['arrive_by'],
        'home_by': wire['home_by'],
        'provider': wire['provider'],
        'has_timetable': wire['has_timetable'],
        'revision': 3,
        'timezone': 'Europe/Prague',
        'warnings': wire['warnings'],
        'items': <Map<String, dynamic>>[
          for (int i = 0; i < items.length; i++)
            <String, dynamic>{
              ...items[i],
              'id': 'srv-$i',
              'local_starts_at': _serverLocal(items[i]['starts_at'] as String),
              'local_ends_at': _serverLocal(items[i]['ends_at'] as String),
            },
        ],
      };

      final TripPlan loaded = TripPlan.fromWire(ctx.tripId, stored);

      expect(loaded.revision, 3);
      expect(loaded.items.length, p.items.length);

      final PlanItem activity = activityOf(loaded);
      expect(activity.isLocked, isTrue, reason: 'zámek musí přežít reload');
      expect(activity.userEdited, isTrue);
      expect(activity.localStart, wall(12, 0));
      expect(activity.duration, const Duration(hours: 2));
      expect(activity.titleParams['title'], 'Prohlídka hradu');

      final PlanItem ride = loaded
          .segment(PlanSegment.outbound)
          .firstWhere((PlanItem i) => i.kind == PlanItemKind.transport);
      expect(ride.detail['line'], 'R 640',
          reason: 'spoj se ukládá jako náš model, ne jako odpověď API');
      expect(loaded.zoneOffset, kTestOffset);
    });

    test('nová položka jde na server bez ID, existující s ním', () {
      final PlanItem fresh = PlanItem.atLocal(
        id: newPlanItemId(),
        kind: PlanItemKind.custom,
        segment: PlanSegment.stay,
        localStart: wall(12, 0),
        localEnd: wall(13, 0),
        zoneOffset: kTestOffset,
        titleKey: kNamedItemKey,
      );
      expect(fresh.isNew, isTrue);
      expect(fresh.toWire()['id'], isNull);

      final PlanItem stored = PlanItem.fromWire(<String, dynamic>{
        ...fresh.toWire(),
        'id': 'srv-9',
        'local_starts_at': naiveOf(12, 0),
        'local_ends_at': naiveOf(13, 0),
      });
      expect(stored.isNew, isFalse);
      expect(stored.toWire()['id'], 'srv-9');
    });
  });

  // -------------------------------------------------------------------------
  group('výběr spoje', () {
    test('při deadlinu vyhrává nejpozdější, který to stihne', () {
      final List<Journey> js = <Journey>[
        earlyHomewardJourney(), // 17:40
        homewardJourney(), // 19:55
        lateHomewardJourney(), // 20:42
      ];
      final Journey? picked =
          JourneyPick.arrivingBy(js, ctx.instant(wall(20, 0)));
      expect(picked?.id, 'home-1',
          reason: 'kdo chce být doma do osmi, chce v cíli zůstat co nejdéle');
    });

    test('nejbližší nevyhovující spoj se dá nabídnout jako náhrada', () {
      final List<Journey> js = <Journey>[
        homewardJourney(),
        lateHomewardJourney(),
      ];
      final Journey? miss =
          JourneyPick.firstAfter(js, ctx.instant(wall(19, 0)));
      expect(miss?.id, 'home-1');
    });

    test('bez deadlinu se bere první odjezd po zadaném čase', () {
      final List<Journey> js = <Journey>[
        outboundJourney(), // odjezd 08:10
        lateOutboundJourney(), // odjezd 12:30
      ];
      expect(
        JourneyPick.departingAfter(js, ctx.instant(wall(9, 0)))?.id,
        'out-late',
      );
      expect(
        JourneyPick.departingAfter(js, ctx.instant(wall(7, 0)))?.id,
        'out-1',
      );
    });
  });
}

/// Co by k okamžiku dopsal server: nástěnné hodiny v zóně výletu.
String _serverLocal(String isoUtc) {
  final DateTime d = DateTime.parse(isoUtc).toUtc().add(kTestOffset);
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}T'
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';
}
