import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/format/cs_format.dart';
import '../../domain/journey.dart';
import '../../domain/plan_change.dart';
import '../../domain/plan_item.dart';
import '../../domain/travel_outline.dart';
import '../../domain/trip_plan.dart';
import '../plan_controller.dart';
import '../plan_strings.dart';
import 'journey_options_sheet.dart';

/// Celý průběh cesty jedním směrem — a místo, kde se s ní dá hýbat.
///
/// Vzorem je vyhledávač jízdních řádů, ne itinerář. Nahoře odjezd a příjezd,
/// se kterými jde posouvat; pod nimi spoj tak, jak pojede.
///
/// Pole ukazují **skutečné** časy nalezeného spoje, ne zadání. Posun je pak
/// to, co člověk čeká: „odjezd v 9:15, chci později" → šipka → hledá se spoj
/// po 9:30. Kdyby pole ukazovala zadání, první stisk by nikam neposunul,
/// protože zadání a skutečnost se skoro nikdy neshodnou.
///
/// Rozdíl mezi přáním a skutečností se proto píše pod pole. Bez toho vypadá
/// obrazovka, jako by zadání ignorovala — spoj, který jede v 9:23, když jste
/// chtěli po 9:15, je správná odpověď, ale bez vysvětlení vypadá jako chyba.
Future<void> showTravelSheet(
  BuildContext context, {
  required String tripId,
  required PlanSegment segment,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
    builder: (BuildContext context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (BuildContext context, ScrollController controller) =>
          _TravelSheet(
        tripId: tripId,
        segment: segment,
        scrollController: controller,
      ),
    ),
  );
}

class _TravelSheet extends ConsumerWidget {
  const _TravelSheet({
    required this.tripId,
    required this.segment,
    required this.scrollController,
  });

  final String tripId;
  final PlanSegment segment;
  final ScrollController scrollController;

  bool get _homeward => segment == PlanSegment.homeward;

  PlanController _controller(WidgetRef ref) =>
      ref.read(planControllerProvider(tripId).notifier);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlanState? state =
        ref.watch(planControllerProvider(tripId)).valueOrNull;
    final TripPlan? plan = state?.plan;
    if (state == null || plan == null) {
      return const Padding(
        padding: EdgeInsets.all(Sp.lg),
        child: PtSkeleton(height: 120),
      );
    }

    final TravelOutline outline = outlineFor(plan.segment(segment));
    final Duration off = plan.zoneOffset;
    final bool busy = state.isReplanning;

    // Zadání pro tenhle směr. Cesta tam se řídí „vyrazit po" a „dorazit do",
    // cesta zpět „vyrazit zpátky v" a „být doma do".
    final DateTime? wantedDeparture = _wall(
      _homeward ? plan.leaveAt : plan.departAfter,
      off,
    );
    final DateTime? wantedArrival = _wall(
      _homeward ? plan.homeBy : plan.arriveBy,
      off,
    );
    final bool anyWanted = wantedDeparture != null || wantedArrival != null;

    // Spoj, o kterém rozhodl člověk. Přepočet ho nesmí vyměnit potichu, a
    // obrazovka to musí říct — jinak vypadá „Přehledat" jako tlačítko, které
    // nic nedělá.
    final bool userPicked = plan.segment(segment).any(
          (PlanItem i) =>
              i.isLocked || i.source == PlanItemSource.userSelected,
        );

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(Sp.lg, 0, Sp.lg, Sp.xl),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                planSegmentLabel(segment),
                style: context.texts.titleMedium,
              ),
            ),
            // Datum toho úseku, ne prvního dne výletu: u dvoudenního výletu
            // se cesta zpět koná jindy a napsat sem první den by byl omyl,
            // podle kterého by někdo přišel na nádraží o den dřív.
            if ((outline.localStart ?? plan.planDate) case final DateTime d)
              Text(
                DateFormat('EEEE d. M.', 'cs').format(d),
                style: context.texts.labelSmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
          ],
        ),
        const SizedBox(height: Sp.sm),

        if (busy) ...<Widget>[
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: Sp.sm),
        ],

        // --- souhrn ---------------------------------------------------------
        if (outline.localStart != null && outline.localEnd != null)
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                '${formatClock(outline.localStart!)} → '
                '${clockWithDay(outline.localEnd!, outline.localStart)}',
                style: context.texts.headlineSmall,
              ),
              const Spacer(),
              if (outline.duration case final Duration d)
                Text(formatSpan(d.inMinutes), style: context.texts.bodyMedium),
            ],
          ),
        if (outline.rides > 0)
          Text(
            outline.transfers == 0
                ? 'bez přestupu'
                : '${outline.transfers} × přestup',
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        if (userPicked)
          Padding(
            padding: const EdgeInsets.only(top: Sp.xxs),
            child: Text(
              'Tenhle spoj jste vybrali sami — přepočet ho nevymění.',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.primary),
            ),
          ),

        const SizedBox(height: Sp.md),
        PtButton(
          label: 'Vyhledat spojení',
          icon: Icons.search,
          expand: true,
          onPressed: busy ? null : () => _choose(context, ref, plan, state),
        ),
        const SizedBox(height: Sp.xs),
        Row(
          children: <Widget>[
            if (userPicked)
              PtButton(
                label: 'Vybrat automaticky',
                variant: PtButtonVariant.text,
                icon: Icons.auto_mode,
                onPressed: busy
                    ? null
                    : () => _controller(ref).apply(RefreshSegment(segment)),
              )
            else
              PtButton(
                label: 'Přehledat',
                variant: PtButtonVariant.text,
                icon: Icons.refresh,
                onPressed: busy
                    ? null
                    : () => _controller(ref).apply(RefreshSegment(segment)),
              ),
            if (anyWanted)
              PtButton(
                label: 'Zrušit zadání',
                variant: PtButtonVariant.text,
                icon: Icons.undo,
                onPressed: busy
                    ? null
                    : () => _controller(ref).apply(
                          _homeward
                              ? const ClearConstraints(
                                  homeBy: true,
                                  leaveAt: true,
                                )
                              : const ClearConstraints(
                                  departAfter: true,
                                  arriveBy: true,
                                ),
                        ),
              ),
          ],
        ),

        const SizedBox(height: Sp.md),

        if (outline.isEmpty)
          const PtEmptyState(
            title: 'Zatím žádný spoj',
            message: 'Pro tenhle úsek plán žádné spojení nemá. Zkuste posunout '
                'čas nebo si spoj vybrat ručně.',
            icon: Icons.train,
          )
        else
          for (final TravelRow r in outline.rows)
            _row(context, r, outline.localStart),

        if (!plan.hasTimetable) ...<Widget>[
          const SizedBox(height: Sp.sm),
          Text(
            'Bez jízdního řádu — časy jsou odhad ze vzdálenosti, ne konkrétní '
            'spoj.',
            style:
                context.texts.labelSmall?.copyWith(color: context.colors.error),
          ),
        ],
        if (state.attribution case final String a) ...<Widget>[
          const SizedBox(height: Sp.sm),
          Text(
            a,
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, TravelRow r, DateTime? firstDay) =>
      switch (r) {
        StopRow() => _StopLine(stop: r, firstDay: firstDay),
        RideRow() => _RideLine(item: r.item),
        LinkRow() => _LinkLine(text: r.text),
      };

  static DateTime? _wall(DateTime? instant, Duration off) =>
      instant == null ? null : PlanItem.wallClockOf(instant, off);

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref,
    TripPlan plan,
    PlanState state,
  ) async {
    final Duration off = plan.zoneOffset;
    final TravelOutline outline = outlineFor(plan.segment(segment));

    // Vyhledávač se otevře tam, kde plán zrovna je. Začínat pokaždé v sedm
    // ráno by znamenalo, že první, co člověk udělá, je oprava data.
    final DateTime when = outline.localStart ??
        _wall(_homeward ? plan.leaveAt : plan.departAfter, off) ??
        plan.planDate ??
        DateTime.now();

    final Journey? picked = await showJourneySheet(
      context,
      title: _homeward ? 'Spoje domů' : 'Spoje do cíle',
      initialWhen: when,
      firstDay: plan.planDate,
      lastDay: state.context?.returnDate ?? plan.planDate,
      lookup: (DateTime whenLocal, {required bool arriveBy}) => _controller(ref)
          .alternatives(segment, whenLocal: whenLocal, arriveBy: arriveBy),
    );
    if (picked == null) return;
    await _controller(ref).apply(ChooseJourney(segment, picked));
  }
}

class _StopLine extends StatelessWidget {
  const _StopLine({required this.stop, this.firstDay});

  final StopRow stop;

  /// Začátek úseku. Noční spoj překročí půlnoc a „0:42" bez dne vypadá jako
  /// chyba v datech.
  final DateTime? firstDay;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 52,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                if (stop.arrival case final DateTime a)
                  Text(
                    clockWithDay(a, firstDay),
                    style: context.texts.labelSmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                if (stop.departure case final DateTime d)
                  Text(
                    clockWithDay(d, firstDay),
                    style: context.texts.labelLarge,
                  ),
              ],
            ),
          ),
          _Dot(color: context.colors.primary),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Sp.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(stop.name, style: context.texts.bodyLarge),
                  if (stop.platform case final String p)
                    Text(
                      'nástupiště $p',
                      style: context.texts.labelSmall
                          ?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RideLine extends StatelessWidget {
  const _RideLine({required this.item});

  final PlanItem item;

  @override
  Widget build(BuildContext context) {
    final Map<String, String> p = item.titleParams;
    final String head = <String>[
      if (p['line'] != null) p['line']!,
      if (p['operator'] != null) p['operator']!,
    ].join(' · ');

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(width: 52),
          _Bar(color: context.colors.primary),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Sp.xs, top: Sp.xxs),
              child: Row(
                children: <Widget>[
                  Icon(
                    planItemIcon(item),
                    size: 18,
                    color: context.colors.primary,
                  ),
                  const SizedBox(width: Sp.xs),
                  Expanded(
                    child: Text(
                      head.isEmpty ? 'Spoj' : head,
                      style: context.texts.bodyMedium,
                    ),
                  ),
                  Text(
                    formatLength(item.duration.inMinutes),
                    style: context.texts.labelSmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pěší přechod nebo čekání. Text u čáry, ne bod na ose — je to poznámka
/// k cestě, ne zastávka, kde se něco děje.
class _LinkLine extends StatelessWidget {
  const _LinkLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(width: 52),
          _Bar(color: context.planto.hairline),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Sp.xs, top: Sp.xxs),
              child: Text(
                text,
                style: context.texts.labelSmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final Color line = context.planto.hairline;
    return SizedBox(
      width: 28,
      child: Column(
        children: <Widget>[
          SizedBox(
            height: Sp.xs,
            child: Center(child: Container(width: 2, color: line)),
          ),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Expanded(
            child: Center(child: Container(width: 2, color: line)),
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      child: Center(child: Container(width: 3, color: color)),
    );
  }
}
