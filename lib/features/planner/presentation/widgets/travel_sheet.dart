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
import 'time_picking.dart';

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

        // --- odjezd a příjezd ----------------------------------------------
        _TimeField(
          label: _homeward ? 'Odjezd zpátky' : 'Odjezd',
          actual: outline.localStart,
          wanted: wantedDeparture,
          wantedPrefix: 'po',
          enabled: !busy,
          onSet: (DateTime t) => _controller(ref)
              .apply(_homeward ? SetLeaveAt(t) : SetDepartAfter(t)),
        ),
        const SizedBox(height: Sp.xs),
        _TimeField(
          label: _homeward ? 'Doma' : 'Příjezd',
          actual: outline.localEnd,
          wanted: wantedArrival,
          wantedPrefix: 'do',
          enabled: !busy,
          onSet: (DateTime t) => _controller(ref)
              .apply(_homeward ? SetHomeBy(t) : SetArriveBy(t)),
        ),

        if (outline.duration case final Duration d) ...<Widget>[
          const SizedBox(height: Sp.xs),
          Text(
            <String>[
              formatSpan(d.inMinutes),
              if (outline.rides > 0)
                outline.transfers == 0
                    ? 'bez přestupu'
                    : '${outline.transfers} × přestup',
            ].join(' · '),
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],

        if (anyWanted) ...<Widget>[
          const SizedBox(height: Sp.xxs),
          Align(
            alignment: Alignment.centerLeft,
            child: PtButton(
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
          ),
        ],

        const SizedBox(height: Sp.sm),
        Row(
          children: <Widget>[
            Expanded(
              child: PtButton(
                label: 'Vybrat spoj',
                variant: PtButtonVariant.tonal,
                icon: Icons.alt_route,
                expand: true,
                onPressed: busy ? null : () => _choose(context, ref),
              ),
            ),
            const SizedBox(width: Sp.xs),
            PtButton(
              label: 'Přehledat',
              variant: PtButtonVariant.text,
              icon: Icons.refresh,
              onPressed: busy
                  ? null
                  : () => _controller(ref).apply(RefreshSegment(segment)),
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

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final Journey? picked = await showJourneySheet(
      context,
      title: _homeward ? 'Spoje domů' : 'Spoje do cíle',
      search: _controller(ref).alternatives(segment),
    );
    if (picked == null) return;
    await _controller(ref).apply(ChooseJourney(segment, picked));
  }
}

/// Jeden čas, se kterým jde hýbat.
///
/// Šipky posouvají po čtvrthodině, klepnutí na hodnotu otevře přesný výběr.
/// Čtvrthodina je kompromis: půlhodina přeskočí spoj, minuta by z posunu
/// udělala třicet klepnutí.
class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.actual,
    required this.wanted,
    required this.wantedPrefix,
    required this.enabled,
    required this.onSet,
  });

  final String label;

  /// Čas nalezeného spoje. To, co člověk čte.
  final DateTime? actual;

  /// Čas, který si člověk zadal. Null, dokud nic nezadal.
  final DateTime? wanted;

  /// „po" u odjezdu, „do" u příjezdu.
  final String wantedPrefix;

  final bool enabled;
  final ValueChanged<DateTime> onSet;

  static const Duration _step = Duration(minutes: 15);

  @override
  Widget build(BuildContext context) {
    // Posouvá se od skutečného času; když spoj není, od zadání.
    final DateTime? base = actual ?? wanted;
    final bool differs = wanted != null &&
        actual != null &&
        wanted!.difference(actual!).inMinutes != 0;

    return PtCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.xs, vertical: Sp.xxs),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: context.texts.labelSmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
                Text(
                  base == null ? '—:—' : formatClock(base),
                  style: context.texts.titleLarge,
                ),
                if (differs)
                  Text(
                    'zadáno: $wantedPrefix ${formatClock(wanted!)}',
                    style: context.texts.labelSmall
                        ?.copyWith(color: context.colors.primary),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove),
            tooltip: 'O čtvrt hodiny dřív',
            onPressed: enabled && base != null
                ? () => onSet(base.subtract(_step))
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'O čtvrt hodiny později',
            onPressed:
                enabled && base != null ? () => onSet(base.add(_step)) : null,
          ),
          IconButton(
            icon: const Icon(Icons.schedule),
            tooltip: 'Zadat přesný čas',
            onPressed: enabled
                ? () async {
                    final DateTime? picked = await pickLocalTime(context, base);
                    if (picked != null) onSet(picked);
                  }
                : null,
          ),
        ],
      ),
    );
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
