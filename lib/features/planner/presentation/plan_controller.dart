import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/failure.dart';
import '../data/journey_repository.dart';
import '../data/plan_repository.dart';
import '../domain/journey.dart';
import '../domain/plan_change.dart';
import '../domain/plan_context.dart';
import '../domain/plan_item.dart';
import '../domain/replanner.dart';
import '../domain/trip_plan.dart';

/// Stav záložky Plán.
///
/// [changedIds] je tu proto, že tichý přepočet je přesně to, co tenhle
/// produkt dělat nesmí. Když se spoj vymění, musí to být na ose vidět —
/// a widget to nemá jak zjistit sám.
@immutable
class PlanState {
  const PlanState({
    this.plan,
    this.context,
    this.gap = PlanContextGap.none,
    this.isReplanning = false,
    this.changedIds = const <String>{},
    this.attribution,
    this.providerError,
  });

  final TripPlan? plan;

  /// Null, když plán zatím nejde postavit — [gap] říká proč.
  final PlanContext? context;
  final PlanContextGap gap;

  final bool isReplanning;

  /// Co se posledním přepočtem pohnulo.
  final Set<String> changedIds;

  /// Povinná atribuce zdrojů dat, když je poskytovatel vyžaduje.
  final String? attribution;

  /// Proč vyhledávač spojení neodpověděl, když neodpověděl.
  ///
  /// „Časy jsou odhad" a „časy jsou odhad, protože vyhledávač spadl" jsou dvě
  /// různé věty. Ta druhá se dá vyřešit; ta první vypadá jako vlastnost
  /// produktu. Server ten důvod posílá — obrazovka ho musí ukázat.
  final String? providerError;

  bool get canPlan => context != null;
  bool get isBuilt => (plan?.items.isNotEmpty ?? false);

  PlanState copyWith({
    TripPlan? plan,
    PlanContext? context,
    PlanContextGap? gap,
    bool? isReplanning,
    Set<String>? changedIds,
    String? attribution,
    String? providerError,
    bool clearProviderError = false,
  }) =>
      PlanState(
        plan: plan ?? this.plan,
        context: context ?? this.context,
        gap: gap ?? this.gap,
        isReplanning: isReplanning ?? this.isReplanning,
        changedIds: changedIds ?? this.changedIds,
        attribution: attribution ?? this.attribution,
        providerError:
            clearProviderError ? null : (providerError ?? this.providerError),
      );
}

/// Orchestrace přepočtu: co je potřeba dohledat → dohledat → přepočítat →
/// uložit.
///
/// Rozhodování je v [Replanner], který je čistý a otestovaný. Tady je jenom
/// pořadí kroků a síť — což je záměr: kdyby byla pravidla o zámcích tady,
/// nešla by otestovat bez Supabase.
class PlanController extends FamilyAsyncNotifier<PlanState, String> {
  static const Replanner _engine = Replanner();

  String? _attribution;
  String? _providerError;

  @override
  Future<PlanState> build(String tripId) async {
    final PlanRepository repo = ref.watch(planRepositoryProvider);
    final PlanContextResult ctx = await repo.context(tripId);
    final TripPlan? plan = await repo.load(tripId);
    return PlanState(
      plan: plan,
      context: ctx.context,
      gap: ctx.gap,
      attribution: _attribution,
      providerError: _providerError,
    );
  }

  /// Postaví plán od nuly. Volá se z tlačítka, ne automaticky při otevření —
  /// dotaz na komunitní vyhledávač se nemá posílat jenom proto, že někdo
  /// přepnul záložku.
  Future<void> rebuild() => apply(const BuildPlan());

  Future<void> apply(PlanChange change) async {
    final PlanState? current = state.valueOrNull;
    final PlanContext? ctx = current?.context;
    if (current == null || ctx == null) return;

    final TripPlan before = current.plan ??
        TripPlan(
          tripId: arg,
          items: const <PlanItem>[],
          timezone: ctx.timezone,
        );

    state = AsyncData<PlanState>(
      current.copyWith(isReplanning: true, changedIds: const <String>{}),
    );

    try {
      final ReplanNeeds needs = _engine.needsFor(before, change, ctx);
      ReplanOutcome outcome = _engine.apply(
        before,
        change,
        ctx,
        outbound: await _search(needs.outbound, ctx),
        homeward: await _search(needs.homeward, ctx),
      );
      final Set<String> changed = <String>{...outcome.changedIds};

      // Druhé kolo, a nejvýš jedno. Vzniká, když se první kolo dozví něco, co
      // před vyhledáním vědět nemohlo — typicky že prodloužená aktivita už
      // nestíhá naplánovaný spoj domů. Třetí kolo by znamenalo, že se pravidla
      // perou mezi sebou, a to je chyba v enginu, ne stav k ošetření.
      if (!outcome.followUp.isEmpty) {
        outcome = _engine.apply(
          outcome.plan,
          const NoChange(),
          ctx,
          needs: outcome.followUp,
          outbound: await _search(outcome.followUp.outbound, ctx),
          homeward: await _search(outcome.followUp.homeward, ctx),
        );
        changed.addAll(outcome.changedIds);
      }

      // Nové položky ještě nemají ID — přiděluje je server. Zvýraznění se
      // proto přenese přes pořadí: `save_trip_plan` ukládá položky v tom
      // pořadí, v jakém přišly, a `trip_plan` je v něm vrací.
      final List<int> changedIndexes = <int>[
        for (int i = 0; i < outcome.plan.items.length; i++)
          if (changed.contains(outcome.plan.items[i].id)) i,
      ];

      final TripPlan saved =
          await ref.read(planRepositoryProvider).save(outcome.plan);

      state = AsyncData<PlanState>(
        current.copyWith(
          plan: saved,
          isReplanning: false,
          attribution: _attribution,
          providerError: _providerError,
          clearProviderError: _providerError == null,
          changedIds: <String>{
            for (final int i in changedIndexes)
              if (i < saved.items.length) saved.items[i].id,
          },
        ),
      );
    } on Failure catch (e) {
      state = AsyncData<PlanState>(current.copyWith(isReplanning: false));
      // Chyba nesmí vygumovat plán, který na obrazovce je. Obrazovka ji
      // ukáže proužkem nad osou — stejný vzor jako u seznamu na balení.
      ref.read(planErrorProvider.notifier).state = e;
      // Konflikt revizí znamená, že plán mezitím změnil někdo jiný. Jediná
      // správná reakce je načíst jeho verzi, ne nabízet „zkusit znovu".
      if (e is ValidationFailure && e.field == 'plan') {
        ref.invalidateSelf();
      }
    }
  }

  /// Spoje pro ruční výběr. Nemění plán — jenom nabídne, z čeho vybrat.
  ///
  /// [whenLocal] jsou nástěnné hodiny v zóně výletu, jak je zadal uživatel ve
  /// vyhledávači. Bez něj se hledá podle toho, co je v plánu — to je stav při
  /// otevření obrazovky.
  Future<JourneySearch> alternatives(
    PlanSegment segment, {
    DateTime? whenLocal,
    bool arriveBy = false,
  }) async {
    final PlanContext? ctx = state.valueOrNull?.context;
    final TripPlan? plan = state.valueOrNull?.plan;
    if (ctx == null) return const JourneySearch.empty();

    final bool homeward = segment == PlanSegment.homeward;

    // Výchozí čas hledání, když se uživatel na nic neptal. „Vyrazíme v pět"
    // přebíjí odjezd, který zrovna v plánu je: je to zadání, kdežto ten
    // odjezd je jeho výsledek.
    final DateTime? current = homeward
        ? (plan?.leaveAt ?? plan?.departureHome)
        : (plan?.departAfter ?? plan?.startsAt);

    final DateTime when = whenLocal != null
        ? ctx.instant(whenLocal)
        : (current ??
            (homeward ? ctx.defaultHomeBy : ctx.defaultDepartAfter));

    final bool by = whenLocal != null
        ? arriveBy
        : (homeward && current == null);

    final JourneyQuery query = JourneyQuery(
      origin: homeward ? ctx.destination : ctx.origin,
      destination: homeward ? ctx.origin : ctx.destination,
      when: when,
      arriveBy: by,
      direction: segment,
    );

    final JourneySearch search = await ref
        .read(journeyRepositoryProvider)
        .search(arg, query, groupSize: ctx.groupSize);
    _attribution = search.attribution ?? _attribution;
    return search;
  }

  /// Vyhledá jeden úsek a vybere z něj spoj podle toho, na co se ptáme.
  Future<SegmentResult?> _search(SegmentNeed? need, PlanContext ctx) async {
    if (need == null) return null;

    final JourneySearch search = await ref
        .read(journeyRepositoryProvider)
        .search(arg, need.query, groupSize: ctx.groupSize);
    _attribution = search.attribution ?? _attribution;
    _providerError = search.providerError;

    final Journey? chosen;
    final Journey? miss;
    if (need.query.arriveBy) {
      // Nejpozdější, který to stihne — kdo chce být doma do osmi, chce v cíli
      // zůstat co nejdéle.
      chosen = JourneyPick.arrivingBy(search.journeys, need.query.when);
      miss = JourneyPick.firstAfter(search.journeys, need.query.when);
    } else {
      chosen = JourneyPick.departingAfter(search.journeys, need.query.when);
      miss = null;
    }

    return SegmentResult(
      chosen: chosen,
      nearestMiss: miss,
      provider: search.provider,
      hasTimetable: search.hasTimetable,
    );
  }
}

final AsyncNotifierProviderFamily<PlanController, PlanState, String>
    planControllerProvider =
    AsyncNotifierProvider.family<PlanController, PlanState, String>(
  PlanController.new,
);

/// Poslední chyba zápisu, kterou obrazovka zobrazí a zahodí.
final StateProvider<Object?> planErrorProvider =
    StateProvider<Object?>((Ref ref) => null);
