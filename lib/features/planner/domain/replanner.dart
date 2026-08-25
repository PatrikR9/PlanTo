/// Přepočet plánu — jádro záložky Plán.
///
/// Čistá funkce nad daty. Žádná síť, žádná databáze, žádný Flutter: engine
/// dostane plán, úpravu a fakta o výletu, a vrátí nový plán. To je jediný
/// důvod, proč se dá otestovat osmnácti testy místo klikání po emulátoru —
/// a zároveň důvod, proč vyhledávání spojení dělá někdo jiný a sem chodí
/// hotový [Journey].
///
/// TŘI PRAVIDLA, KTERÁ SE NESMÍ PORUŠIT
///
/// 1. Zamčená položka se nehne. Když jinak nejde zadání splnit, vrátí se
///    problém — ne posunutý zámek.
/// 2. Ručně vybraný spoj se nevymění potichu. Buď zůstane, nebo se vymění
///    a v [ReplanOutcome.problems] o tom je záznam.
/// 3. Přepočítá se jenom to, co se změnou souvisí. „Chci být doma do osmi"
///    nesmí sáhnout na cestu tam.
///
/// Třetí pravidlo je zároveň důvod, proč [Replanner.needsFor] existuje jako
/// samostatný krok: nejdřív se zjistí, které úseky je vůbec potřeba hledat,
/// a teprve pak se hledají. Přepočítat všechno by bylo jednodušší napsat a
/// dražší na komunitní službě, kterou nikdo neplatí.
library;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'journey.dart';
import 'plan_change.dart';
import 'plan_context.dart';
import 'plan_item.dart';
import 'plan_problem.dart';
import 'trip_plan.dart';

/// Proč se úsek hledá znovu. Rozhoduje, jestli se smí přepsat zámek.
enum SegmentIntent {
  /// Uživatel řekl přímo o tomhle úseku „najdi jiný spoj". Přebíjí zámek
  /// i ruční výběr, protože je to vědomé rozhodnutí o téhle věci.
  explicit,

  /// Uživatel změnil podmínku, která tenhle úsek řídí („chci dorazit do
  /// dvanácti"). Spoj se vymění, ale ruční výběr se připomene.
  constraint,

  /// Úsek se hledá kvůli něčemu jinému — posunula se aktivita a návrat se
  /// nestíhá. Zámek ani ruční výběr se nepřepisují.
  cascade,
}

/// Jeden úsek, který je potřeba dohledat.
@immutable
class SegmentNeed {
  const SegmentNeed(this.query, this.intent);

  final JourneyQuery query;
  final SegmentIntent intent;
}

/// Co engine potřebuje zvenčí, než změnu dokončí.
@immutable
class ReplanNeeds {
  const ReplanNeeds({this.outbound, this.homeward});

  static const ReplanNeeds none = ReplanNeeds();

  final SegmentNeed? outbound;
  final SegmentNeed? homeward;

  bool get isEmpty => outbound == null && homeward == null;
}

/// Výsledek vyhledání jednoho úseku, jak ho engine potřebuje.
@immutable
class SegmentResult {
  const SegmentResult({
    this.chosen,
    this.nearestMiss,
    this.provider,
    this.hasTimetable = false,
  });

  /// Spoj, který se do zadání vešel.
  final Journey? chosen;

  /// Nejbližší spoj, který se do zadání **nevešel**. Existuje jenom kvůli
  /// hlášce: „nejbližší možný návrat je ve 20:42" je použitelná věta,
  /// „nenašel jsem nic" není.
  final Journey? nearestMiss;

  final String? provider;

  /// False = časy jsou geometrický odhad, ne jízdní řád.
  final bool hasTimetable;

  bool get isEmpty => chosen == null;
}

/// Nový plán plus to, co o něm uživatel musí vědět.
@immutable
class ReplanOutcome {
  const ReplanOutcome({
    required this.plan,
    this.changedIds = const <String>{},
    this.problems = const <PlanProblem>[],
    this.followUp = ReplanNeeds.none,
  });

  final TripPlan plan;

  /// ID položek, které se změnou pohnuly. Osa je zvýrazní — tichá změna
  /// spoje je přesně to, co tenhle produkt dělat nesmí.
  final Set<String> changedIds;

  final List<PlanProblem> problems;

  /// Úseky, které je potřeba dohledat v druhém kole. Vzniká, když se během
  /// přepočtu ukáže, že změna jednoho úseku shodila druhý — typicky
  /// prodloužená aktivita, na kterou už nenavazuje původní spoj domů.
  final ReplanNeeds followUp;
}

/// Výběr spoje ze seznamu. Čistý a testovatelný, protože „který z těch pěti"
/// je rozhodnutí o produktu, ne o parsování.
abstract final class JourneyPick {
  /// Nejpozdější spoj, který ještě dorazí do [deadline].
  ///
  /// Nejpozdější, ne nejdřívější: kdo chce být doma do osmi, chce v cíli
  /// zůstat co nejdéle. Nejdřívější spoj splňuje zadání taky, a je to špatná
  /// odpověď.
  static Journey? arrivingBy(List<Journey> journeys, DateTime deadline) {
    final List<Journey> fits = journeys
        .where((Journey j) => !j.arrival.isAfter(deadline))
        .toList()
      // Při shodě rozhoduje ID. Bez druhého kritéria vrátí `sort` pro stejná
      // data dvě různá pořadí a „doporučený spoj" by se měnil sám od sebe.
      ..sort((Journey a, Journey b) {
        final int t = b.arrival.compareTo(a.arrival);
        return t != 0 ? t : a.id.compareTo(b.id);
      });
    return fits.firstOrNull;
  }

  /// První spoj, který se do [deadline] nevešel — pro hlášku o nejbližší
  /// možné variantě.
  static Journey? firstAfter(List<Journey> journeys, DateTime deadline) {
    final List<Journey> late = journeys
        .where((Journey j) => j.arrival.isAfter(deadline))
        .toList()
      ..sort((Journey a, Journey b) => a.arrival.compareTo(b.arrival));
    return late.firstOrNull;
  }

  /// Nejdřívější spoj, který odjíždí nejdřív v [earliest].
  static Journey? departingAfter(List<Journey> journeys, DateTime earliest) {
    final List<Journey> fits = journeys
        .where((Journey j) => !j.departure.isBefore(earliest))
        .toList()
      ..sort((Journey a, Journey b) => a.departure.compareTo(b.departure));
    return fits.firstOrNull;
  }
}

class Replanner {
  const Replanner();

  /// Které úseky je potřeba dohledat, než se změna dá provést.
  ReplanNeeds needsFor(TripPlan plan, PlanChange change, PlanContext ctx) =>
      _localPass(plan, change, ctx).needs;

  /// Provede změnu. [outbound] a [homeward] jsou výsledky vyhledání, které si
  /// volající vyžádal podle [needsFor]; když je engine nepotřebuje, ignoruje
  /// je.
  ReplanOutcome apply(
    TripPlan plan,
    PlanChange change,
    PlanContext ctx, {
    SegmentResult? outbound,
    SegmentResult? homeward,
    ReplanNeeds? needs,
  }) {
    final _LocalPass raw = _localPass(plan, change, ctx);
    final _LocalPass pass = needs == null
        ? raw
        : _LocalPass(
            plan: raw.plan,
            changed: raw.changed,
            problems: raw.problems,
            needs: needs,
          );
    TripPlan p = pass.plan;
    final Set<String> changed = <String>{...pass.changed};
    final List<PlanProblem> problems = <PlanProblem>[...pass.problems];

    p = _spliceSegment(
      p,
      ctx,
      PlanSegment.outbound,
      pass.needs.outbound,
      outbound,
      changed,
      problems,
    );
    p = _spliceSegment(
      p,
      ctx,
      PlanSegment.homeward,
      pass.needs.homeward,
      homeward,
      changed,
      problems,
    );

    // Poskytovatel a jízdní řád se berou z toho, co doopravdy odpovědělo.
    final SegmentResult? any = outbound ?? homeward;
    if (any != null && any.provider != null) {
      p = p.copyWith(provider: any.provider, hasTimetable: any.hasTimetable);
    }

    p = _fillStay(p, ctx, changed);
    final ({TripPlan plan, ReplanNeeds needs}) flowed =
        _reflow(p, ctx, changed, problems);
    p = flowed.plan;
    p = _validate(p, ctx, problems);

    return ReplanOutcome(
      plan: p.sorted().copyWith(warnings: problems),
      changedIds: changed,
      problems: problems,
      followUp: flowed.needs,
    );
  }

  // -------------------------------------------------------------------------
  // Lokální průchod
  // -------------------------------------------------------------------------

  _LocalPass _localPass(TripPlan plan, PlanChange change, PlanContext ctx) {
    TripPlan p = plan;
    final Set<String> changed = <String>{};
    final List<PlanProblem> problems = <PlanProblem>[];
    SegmentNeed? needOut;
    SegmentNeed? needHome;

    // Každá větev má vlastní blok. Bez závorek sdílejí case-y v Dartu jeden
    // rozsah a druhé `final PlanItem? item` je chyba překladu, ne stín.
    switch (change) {
      case NoChange():
        break;

      case BuildPlan():
        {
          p = p.copyWith(items: const <PlanItem>[], planDate: ctx.planDate);
          needOut = SegmentNeed(_outboundQuery(p, ctx), SegmentIntent.explicit);
          needHome =
              SegmentNeed(_homewardQuery(p, ctx), SegmentIntent.explicit);
        }

      case RefreshSegment(segment: final PlanSegment refreshed):
        {
          if (refreshed == PlanSegment.homeward) {
            needHome = SegmentNeed(
              _homewardQuery(p, ctx),
              SegmentIntent.explicit,
            );
          } else {
            needOut = SegmentNeed(
              _outboundQuery(p, ctx),
              SegmentIntent.explicit,
            );
          }
        }

      case SetDepartAfter(localTime: final DateTime departLocal):
        {
          // „Vyrazím po sedmé" a „chci tam být do dvanácti" jsou dvě odpovědi
          // na tutéž otázku. Nastavit obojí znamená, že jedna z nich se tiše
          // ignoruje — proto se ta druhá ruší.
          p = p.copyWith(
            departAfter: ctx.instant(departLocal),
            clearArriveBy: true,
          );
          needOut =
              SegmentNeed(_outboundQuery(p, ctx), SegmentIntent.constraint);
        }

      case SetArriveBy(localTime: final DateTime arriveLocal):
        {
          p = p.copyWith(
            arriveBy: ctx.instant(arriveLocal),
            clearDepartAfter: true,
          );
          needOut =
              SegmentNeed(_outboundQuery(p, ctx), SegmentIntent.constraint);
        }

      case SetHomeBy(localTime: final DateTime homeLocal):
        {
          // „Být doma do osmi" a „vyrazit v pět" jsou dvě odpovědi na tutéž
          // otázku. Nechat obojí znamená, že jedna z nich se tiše ignoruje.
          p = p.copyWith(
            homeBy: ctx.instant(homeLocal),
            clearLeaveAt: true,
          );
          needHome = SegmentNeed(
            _homewardByDeadline(p, ctx),
            SegmentIntent.constraint,
          );
        }

      case SetLeaveAt(localTime: final DateTime leaveLocal):
        {
          p = p.copyWith(
            leaveAt: ctx.instant(leaveLocal),
            clearHomeBy: true,
          );
          needHome = SegmentNeed(
            _homewardQuery(p, ctx),
            SegmentIntent.constraint,
          );
        }

      case ClearConstraints(
          departAfter: final bool clearDepart,
          arriveBy: final bool clearArrive,
          homeBy: final bool clearHome,
          leaveAt: final bool clearLeave,
        ):
        {
          p = p.copyWith(
            clearDepartAfter: clearDepart,
            clearArriveBy: clearArrive,
            clearHomeBy: clearHome,
            clearLeaveAt: clearLeave,
          );
          if (clearDepart || clearArrive) {
            needOut =
                SegmentNeed(_outboundQuery(p, ctx), SegmentIntent.constraint);
          }
          if (clearHome || clearLeave) {
            needHome = SegmentNeed(
              _homewardQuery(p, ctx),
              SegmentIntent.constraint,
            );
          }
        }

      case MoveItem(itemId: final String moveId, localStart: final DateTime to):
        {
          final PlanItem? target = p.itemById(moveId);
          if (target == null) break;
          final PlanItem moved =
              target.movedToLocal(to).copyWith(userEdited: true);
          p = _replaceItem(p, moved);
          changed.add(moved.id);
        }

      case ResizeItem(
          itemId: final String resizeId,
          duration: final Duration span,
        ):
        {
          final PlanItem? target = p.itemById(resizeId);
          if (target == null || span <= Duration.zero) break;
          final PlanItem resized =
              target.resizedTo(span).copyWith(userEdited: true);
          p = _replaceItem(p, resized);
          changed.add(resized.id);
        }

      case EditItem(
          itemId: final String editId,
          localStart: final DateTime? newStart,
          duration: final Duration? newLength,
          title: final String? newTitle,
          note: final String? newNote,
          locked: final bool? newLocked,
        ):
        {
          final PlanItem? target = p.itemById(editId);
          if (target == null) break;
          PlanItem it = target;
          bool edited = false;
          if (newStart != null && newStart != it.localStart) {
            it = it.movedToLocal(newStart);
            edited = true;
          }
          if (newLength != null &&
              newLength > Duration.zero &&
              newLength != it.duration) {
            it = it.resizedTo(newLength);
            edited = true;
          }
          if (newTitle != null || newNote != null) {
            it = it.copyWith(
              // Vlastní název přebíjí generovaný klíč. Kdyby ho jenom přidal
              // do parametrů, zůstalo by na ose „Program v Krumlově" a člověk
              // by nevěděl, kam se jeho text poděl.
              titleKey: newTitle != null && newTitle.trim().isNotEmpty
                  ? kNamedItemKey
                  : it.titleKey,
              titleParams: <String, String>{
                ...it.titleParams,
                if (newTitle != null) 'title': newTitle.trim(),
                if (newNote != null) 'note': newNote.trim(),
              },
            );
            edited = true;
          }
          if (newLocked != null) it = it.copyWith(isLocked: newLocked);
          p = _replaceItem(p, it.copyWith(userEdited: it.userEdited || edited));
          changed.add(it.id);
        }

      case SetItemLocked(itemId: final String lockId, locked: final bool lock):
        {
          final PlanItem? target = p.itemById(lockId);
          if (target == null) break;
          p = _replaceItem(p, target.copyWith(isLocked: lock));
          changed.add(lockId);
        }

      case AddItem(item: final PlanItem added):
        {
          p = p.copyWith(items: <PlanItem>[...p.items, added]);
          changed.add(added.id);
        }

      case UpdateItem(item: final PlanItem updated):
        {
          // Časy tudy neprocházejí. Zachovají se z původní položky, aby se na
          // posun nedaly dvě cesty — jedna z nich by zapomněla přepočítat
          // zbytek plánu.
          final PlanItem? old = p.itemById(updated.id);
          if (old == null) break;
          p = _replaceItem(
            p,
            updated.copyWith(
              startsAt: old.startsAt,
              endsAt: old.endsAt,
              localStart: old.localStart,
              localEnd: old.localEnd,
              userEdited: true,
            ),
          );
          changed.add(updated.id);
        }

      case RemoveItem(itemId: final String removeId):
        {
          final PlanItem? target = p.itemById(removeId);
          // Úsek cesty se nemaže tlačítkem. Zmizel by z osy a plán by tvrdil,
          // že se skupina teleportuje.
          if (target == null || !target.canDelete) break;
          p = p.copyWith(
            items: p.items.where((PlanItem i) => i.id != removeId).toList(),
          );
          changed.add(removeId);
        }

      case ChooseJourney(
          segment: final PlanSegment chosenSegment,
          journey: final Journey chosenJourney,
        ):
        {
          final List<PlanItem> replacement = _itemsForJourney(
            chosenJourney,
            chosenSegment,
            ctx,
            source: PlanItemSource.userSelected,
            locked: true,
          );
          for (final PlanItem i in p.segment(chosenSegment)) {
            changed.add(i.id);
          }
          for (final PlanItem i in replacement) {
            changed.add(i.id);
          }
          p = p.copyWith(
            items: <PlanItem>[
              ...p.items.where((PlanItem i) => i.segment != chosenSegment),
              ...replacement,
            ],
          );
        }
    }

    return _LocalPass(
      plan: p,
      changed: changed,
      problems: problems,
      needs: ReplanNeeds(outbound: needOut, homeward: needHome),
    );
  }

  // -------------------------------------------------------------------------
  // Dotazy
  // -------------------------------------------------------------------------

  JourneyQuery _outboundQuery(TripPlan p, PlanContext ctx) {
    final DateTime? arriveBy = p.arriveBy;
    return JourneyQuery(
      origin: ctx.origin,
      destination: ctx.destination,
      when: arriveBy ?? p.departAfter ?? ctx.defaultDepartAfter,
      arriveBy: arriveBy != null,
      direction: PlanSegment.outbound,
    );
  }

  /// Cesta zpět podle toho, co je zadané.
  ///
  /// „Vyrazíme v pět" je dotaz na odjezd, „být doma do osmi" na příjezd. Jsou
  /// to dvě různá hledání a nedají se navzájem odvodit: spoj, který vyjíždí
  /// nejdřív po páté, není spoj, který dojede nejpozději v osm.
  JourneyQuery _homewardQuery(TripPlan p, PlanContext ctx) {
    final DateTime? leaveAt = p.leaveAt;
    if (leaveAt == null) return _homewardByDeadline(p, ctx);
    return JourneyQuery(
      origin: ctx.destination,
      destination: ctx.origin,
      when: leaveAt,
      arriveBy: false,
      direction: PlanSegment.homeward,
    );
  }

  /// Cesta zpět podle deadlinu: „být doma do osmi".
  ///
  /// Samostatný dotaz, ne obrácená cesta tam. Odpolední spoje jsou jiné než
  /// ranní, jezdí jinak často a v neděli úplně jinak — otočit ranní itinerář
  /// by byl vymyšlený jízdní řád.
  JourneyQuery _homewardByDeadline(TripPlan p, PlanContext ctx) => JourneyQuery(
        origin: ctx.destination,
        destination: ctx.origin,
        when: p.homeBy ?? ctx.defaultHomeBy,
        arriveBy: true,
        direction: PlanSegment.homeward,
      );

  /// Cesta zpět po skončení programu: „vyrazíme, až tohle dojede".
  JourneyQuery _homewardAfterStay(PlanContext ctx, DateTime stayEnd) =>
      JourneyQuery(
        origin: ctx.destination,
        destination: ctx.origin,
        when: stayEnd.add(ctx.readyBeforeDeparture),
        arriveBy: false,
        direction: PlanSegment.homeward,
      );

  // -------------------------------------------------------------------------
  // Vložení nalezeného úseku
  // -------------------------------------------------------------------------

  TripPlan _spliceSegment(
    TripPlan p,
    PlanContext ctx,
    PlanSegment segment,
    SegmentNeed? need,
    SegmentResult? result,
    Set<String> changed,
    List<PlanProblem> problems,
  ) {
    if (need == null) return p;

    final List<PlanItem> existing = p.segment(segment);
    final bool isUserChoice = existing.any(
      (PlanItem i) => i.isLocked || i.source == PlanItemSource.userSelected,
    );

    // Pravidlo 2: zamčený nebo ručně vybraný spoj se nemění, dokud o to
    // uživatel nepožádal přímo.
    if (isUserChoice && need.intent == SegmentIntent.cascade) {
      problems.add(
        PlanProblem(
          PlanProblemCode.lockedConflict,
          params: <String, String>{'segment': segment.wire},
        ),
      );
      return p;
    }

    if (result == null || result.isEmpty) {
      // Nic se nenašlo. Původní úsek zůstává, protože plán bez cesty je
      // horší než plán s cestou, která nesplňuje nové zadání — a hláška
      // řekne, co se stalo.
      final Journey? miss = result?.nearestMiss;
      problems.add(
        PlanProblem(
          segment == PlanSegment.homeward
              ? PlanProblemCode.noReturnFound
              : PlanProblemCode.noOutboundFound,
          params: <String, String>{
            if (miss != null) 'earliest': _wall(miss.localArrival),
            if (miss != null) 'departure': _wall(miss.localDeparture),
          },
        ),
      );
      return p;
    }

    if (isUserChoice && need.intent == SegmentIntent.constraint) {
      problems.add(
        PlanProblem(
          PlanProblemCode.userChoiceReplaced,
          params: <String, String>{'segment': segment.wire},
        ),
      );
    }

    final List<PlanItem> replacement = _itemsForJourney(
      result.chosen!,
      segment,
      ctx,
      source: PlanItemSource.provider,
      locked: false,
    );

    for (final PlanItem i in existing) {
      changed.add(i.id);
    }
    for (final PlanItem i in replacement) {
      changed.add(i.id);
    }

    return p.copyWith(
      items: <PlanItem>[
        ...p.items.where((PlanItem i) => i.segment != segment),
        ...replacement,
      ],
    );
  }

  /// Spojení na položky časové osy.
  ///
  /// Přestupy vznikají tady, ne na serveru: je to rozdíl dvou časů, které už
  /// máme, a druhé číslo o téže věci je jenom příležitost, aby se ta dvě
  /// rozešla.
  List<PlanItem> _itemsForJourney(
    Journey j,
    PlanSegment segment,
    PlanContext ctx, {
    required PlanItemSource source,
    required bool locked,
  }) {
    final List<PlanItem> out = <PlanItem>[];
    final Duration off = ctx.zoneOffset;

    // Odchod z domova. Přidává se jen tehdy, když spojení nezačíná chůzí —
    // s vlastním MOTISem začíná, s geometrickým odhadem ne, a v obou
    // případech má osa začínat tím, kdy se má člověk zvednout.
    final JourneyLeg? first = j.legs.firstOrNull;
    if (first != null && !first.isWalk && segment == PlanSegment.outbound) {
      out.add(
        PlanItem.atLocal(
          id: newPlanItemId(),
          kind: PlanItemKind.walk,
          segment: segment,
          localStart: first.localDeparture.subtract(ctx.homeWalk),
          localEnd: first.localDeparture,
          zoneOffset: off,
          titleKey: 'plan.leave_home',
          titleParams: <String, String>{'stop': first.fromName},
          toName: first.fromName,
          confidence: PlanConfidence.rough,
          source: source,
        ),
      );
    }

    JourneyLeg? previous;
    for (final JourneyLeg leg in j.legs) {
      if (previous != null) {
        final Duration wait = leg.departure.difference(previous.arrival);
        if (wait.inMinutes >= 1) {
          out.add(
            PlanItem.atLocal(
              id: newPlanItemId(),
              kind: PlanItemKind.transfer,
              segment: segment,
              localStart: previous.localArrival,
              localEnd: leg.localDeparture,
              zoneOffset: off,
              titleKey: 'plan.transfer',
              titleParams: <String, String>{
                'stop': previous.toName,
                'minutes': '${wait.inMinutes}',
              },
              fromName: previous.toName,
              toName: leg.fromName,
              confidence: PlanConfidence.estimated,
              source: source,
              isLocked: locked,
            ),
          );
        }
      }

      out.add(
        PlanItem.atLocal(
          id: newPlanItemId(),
          kind: leg.isWalk ? PlanItemKind.walk : PlanItemKind.transport,
          segment: segment,
          localStart: leg.localDeparture,
          localEnd: leg.localArrival,
          zoneOffset: off,
          titleKey: leg.isWalk ? 'plan.walk' : 'plan.ride',
          titleParams: <String, String>{
            'from': leg.fromName,
            'to': leg.toName,
            if (leg.lineName != null) 'line': leg.lineName!,
            if (leg.operatorName != null) 'operator': leg.operatorName!,
          },
          // Náš model úseku, ne odpověď poskytovatele. Proto to po roce a po
          // výměně vyhledávače pořád půjde načíst.
          detail: <String, dynamic>{
            ...leg.toWire(),
            'journey_id': j.id,
            if (j.deepLink != null) 'deep_link': j.deepLink,
          },
          fromName: leg.fromName,
          toName: leg.toName,
          confidence: PlanConfidence.estimated,
          source: source,
          isLocked: locked,
        ),
      );

      previous = leg;
    }

    // Cesta od zastávky domů.
    final JourneyLeg? last = j.legs.lastOrNull;
    if (last != null && !last.isWalk && segment == PlanSegment.homeward) {
      out.add(
        PlanItem.atLocal(
          id: newPlanItemId(),
          kind: PlanItemKind.walk,
          segment: segment,
          localStart: last.localArrival,
          localEnd: last.localArrival.add(ctx.homeWalk),
          zoneOffset: off,
          titleKey: 'plan.walk_home',
          titleParams: <String, String>{'stop': last.toName},
          fromName: last.toName,
          confidence: PlanConfidence.rough,
          source: source,
        ),
      );
    }

    // Jízdné visí na prvním úseku a nese v detailu, že platí pro celou cestu.
    // Rozpočítat ho po legách by znamenalo vyrobit čísla, která z tarifu
    // neplynou — integrované jízdenky nejsou součet dílčích.
    final FareEstimate? fare = j.fare;
    if (fare != null) {
      final int i = out.indexWhere(
        (PlanItem it) => it.kind == PlanItemKind.transport,
      );
      if (i >= 0) {
        out[i] = out[i].copyWith(
          costMin: fare.min,
          costMax: fare.max,
          currency: fare.currency,
          confidence: PlanConfidence.estimated,
          detail: <String, dynamic>{
            ...out[i].detail,
            'fare': fare.toWire(),
            'fare_covers': 'journey',
          },
        );
      }
    }

    return out;
  }

  // -------------------------------------------------------------------------
  // Program v cíli
  // -------------------------------------------------------------------------

  /// Doplní program, když v cíli nic není. Nemaže a nepřepisuje: existující
  /// aktivity jsou to nejcennější, co v plánu je.
  TripPlan _fillStay(TripPlan p, PlanContext ctx, Set<String> changed) {
    if (p.segment(PlanSegment.stay).isNotEmpty) return p;

    final DateTime? arrival = p.arrivalAtDestination;
    final DateTime? departure = p.departureHome;
    if (arrival == null || departure == null) return p;

    final DateTime start = arrival.add(ctx.settleAfterArrival);
    final DateTime end = departure.subtract(ctx.readyBeforeDeparture);
    if (!end.isAfter(start)) return p;

    final PlanItem activity = PlanItem.atLocal(
      id: newPlanItemId(),
      kind: PlanItemKind.activity,
      segment: PlanSegment.stay,
      localStart: ctx.wallClock(start),
      localEnd: ctx.wallClock(end),
      zoneOffset: ctx.zoneOffset,
      titleKey: 'plan.activity_default',
      titleParams: <String, String>{'place': ctx.destination.name},
      placeId: ctx.destination.placeId,
      toName: ctx.destination.name,
      confidence: PlanConfidence.rough,
    );
    changed.add(activity.id);
    return p.copyWith(items: <PlanItem>[...p.items, activity]);
  }

  // -------------------------------------------------------------------------
  // Srovnání osy
  // -------------------------------------------------------------------------

  /// Posune, co se posunout smí, a nahlásí, co se posunout nesmělo.
  ///
  /// Vrací případný požadavek na druhé kolo: když program skončí až po
  /// odjezdu naplánovaného spoje domů, není co srovnávat — je potřeba jiný
  /// spoj.
  ({TripPlan plan, ReplanNeeds needs}) _reflow(
    TripPlan plan,
    PlanContext ctx,
    Set<String> changed,
    List<PlanProblem> problems,
  ) {
    final TripPlan p = plan.sorted();
    final DateTime? arrival = p.arrivalAtDestination;
    final List<PlanItem> stay = p.segment(PlanSegment.stay);

    if (stay.isEmpty || arrival == null) {
      return (plan: p.sorted(), needs: ReplanNeeds.none);
    }

    // --- co začíná dřív, než se dá dorazit ----------------------------------
    // Program se **neseřazuje do fronty**. Oběd uvnitř prohlídky je legitimní
    // překryv a odsunout ho za ni jenom proto, že je v seznamu druhý, by
    // rozbilo plán, který dával smysl. Jediné pravidlo je „nic nezačne dřív,
    // než skupina dorazí".
    final DateTime notBefore = arrival.add(ctx.settleAfterArrival);
    DateTime stayEnd = notBefore;
    final List<PlanItem> rebuilt = <PlanItem>[];
    for (final PlanItem item in stay) {
      PlanItem it = item;
      if (it.startsAt.isBefore(notBefore)) {
        if (it.isLocked) {
          // Pravidlo 1. Zámek se nehne ani kvůli tomu, že se na něj nestíhá.
          problems.add(
            PlanProblem(
              PlanProblemCode.arrivalAfterActivity,
              params: <String, String>{
                'arrival': _wall(ctx.wallClock(arrival)),
                'start': _wall(it.localStart),
              },
            ),
          );
        } else {
          it = it.shiftedBy(notBefore.difference(it.startsAt));
          changed.add(it.id);
        }
      }
      rebuilt.add(it);
      if (it.endsAt.isAfter(stayEnd)) stayEnd = it.endsAt;
    }

    final DateTime? departure = p.departureHome;
    if (departure == null ||
        !stayEnd.add(ctx.readyBeforeDeparture).isAfter(departure)) {
      return (plan: _withStay(p, rebuilt).sorted(), needs: ReplanNeeds.none);
    }

    // --- program přerostl odjezd domů ---------------------------------------
    final bool homewardFixed = p.segment(PlanSegment.homeward).any(
          (PlanItem i) => i.isLocked || i.source == PlanItemSource.userSelected,
        );

    if (!homewardFixed) {
      // Spoj domů si vybral engine, takže se smí hledat jiný. To je ta levná
      // varianta: cesta tam ani program se nepřepočítávají.
      return (
        plan: _withStay(p, rebuilt).sorted(),
        needs: ReplanNeeds(
          homeward: SegmentNeed(
            _homewardAfterStay(ctx, stayEnd),
            SegmentIntent.cascade,
          ),
        ),
      );
    }

    // Zamčený nebo ručně vybraný návrat se nehledá znovu — zkrátí se program.
    // Je to menší změna než vyměnit spoj, o kterém uživatel rozhodl sám, a
    // hlavně to nemění nic, co si nastavil.
    final DateTime limit = departure.subtract(ctx.readyBeforeDeparture);
    final int last = rebuilt.lastIndexWhere((PlanItem i) => !i.isLocked);
    if (last >= 0 && limit.isAfter(rebuilt[last].startsAt.add(_minimumStay))) {
      final PlanItem shortened =
          rebuilt[last].resizedTo(limit.difference(rebuilt[last].startsAt));
      rebuilt[last] = shortened;
      changed.add(shortened.id);
    } else {
      problems.add(
        const PlanProblem(
          PlanProblemCode.lockedConflict,
          params: <String, String>{'segment': 'stay'},
        ),
      );
    }

    return (plan: _withStay(p, rebuilt).sorted(), needs: ReplanNeeds.none);
  }

  /// Nahradí pobyt novou sadou položek a nechá zbytek plánu být.
  TripPlan _withStay(TripPlan p, List<PlanItem> stay) => p.copyWith(
        items: <PlanItem>[
          ...p.items.where((PlanItem i) => i.segment != PlanSegment.stay),
          ...stay,
        ],
      );

  // -------------------------------------------------------------------------
  // Kontrola
  // -------------------------------------------------------------------------

  TripPlan _validate(
    TripPlan p,
    PlanContext ctx,
    List<PlanProblem> problems,
  ) {
    final DateTime? arriveBy = p.arriveBy;
    final DateTime? arrival = p.arrivalAtDestination;
    if (arriveBy != null && arrival != null && arrival.isAfter(arriveBy)) {
      problems.add(
        PlanProblem(
          PlanProblemCode.arrivalAfterRequest,
          params: <String, String>{
            'requested': _wall(ctx.wallClock(arriveBy)),
            'actual': _wall(ctx.wallClock(arrival)),
          },
        ),
      );
    }

    final DateTime? homeBy = p.homeBy;
    final DateTime? home = p.arrivalHome;
    if (homeBy != null && home != null && home.isAfter(homeBy)) {
      problems.add(
        PlanProblem(
          PlanProblemCode.returnAfterDeadline,
          params: <String, String>{
            'deadline': _wall(ctx.wallClock(homeBy)),
            'actual': _wall(ctx.wallClock(home)),
          },
        ),
      );
    }

    if (p.items.isNotEmpty && !p.hasTimetable) {
      problems.add(const PlanProblem(PlanProblemCode.noTimetable));
    }

    return p;
  }

  // -------------------------------------------------------------------------

  TripPlan _replaceItem(TripPlan p, PlanItem item) => p.copyWith(
        items: <PlanItem>[
          for (final PlanItem i in p.items)
            if (i.id == item.id) item else i,
        ],
      );
}

/// Kratší program než tohle už není program.
const Duration _minimumStay = Duration(minutes: 15);

@immutable
class _LocalPass {
  const _LocalPass({
    required this.plan,
    required this.changed,
    required this.problems,
    required this.needs,
  });

  final TripPlan plan;
  final Set<String> changed;
  final List<PlanProblem> problems;
  final ReplanNeeds needs;
}

/// Čas do parametru hlášky. Naivní ISO v zóně výletu — prezentační vrstva ho
/// naformátuje, ale nemusí ho znovu převádět.
String _wall(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}T'
    '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';
