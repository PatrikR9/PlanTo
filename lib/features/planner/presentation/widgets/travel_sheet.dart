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
/// Vzorem je vyhledávač jízdních řádů, ne itinerář: nahoře čas, podle kterého
/// se hledá, pod ním spoj tak, jak pojede. Posunout odjezd o půl hodiny je
/// jedno klepnutí, protože přesně to člověk u plánu dělá nejčastěji.
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
            if (plan.planDate case final DateTime d)
              Text(
                DateFormat('EEEE d. M.', 'cs').format(d),
                style: context.texts.labelSmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
          ],
        ),
        const SizedBox(height: Sp.xs),

        if (outline.localStart != null && outline.localEnd != null)
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                '${formatClock(outline.localStart!)} → '
                '${formatClock(outline.localEnd!)}',
                style: context.texts.headlineSmall,
              ),
              const Spacer(),
              if (outline.duration case final Duration d)
                Text(formatLength(d.inMinutes), style: context.texts.bodyMedium),
            ],
          ),

        const SizedBox(height: Sp.sm),
        if (busy) ...<Widget>[
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: Sp.sm),
        ],

        // --- zadání, podle kterého se hledá --------------------------------
        _Stepper(
          label: _homeward ? 'Být doma do' : 'Vyrazit po',
          value: _primaryValue(plan, outline, off),
          enabled: !busy,
          onChanged: (DateTime local) => _setPrimary(ref, local),
        ),
        if (!_homeward) ...<Widget>[
          const SizedBox(height: Sp.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: ActionChip(
              avatar: const Icon(Icons.flag_outlined, size: 18),
              label: Text(
                plan.arriveBy == null
                    ? 'Dorazit do…'
                    : 'Dorazit do '
                        '${formatClock(PlanItem.wallClockOf(plan.arriveBy!, off))}',
              ),
              onPressed: busy
                  ? null
                  : () async {
                      final DateTime? picked = await _pickTime(
                        context,
                        plan.arriveBy == null
                            ? outline.localEnd
                            : PlanItem.wallClockOf(plan.arriveBy!, off),
                      );
                      if (picked != null) {
                        await _controller(ref).apply(SetArriveBy(picked));
                      }
                    },
            ),
          ),
        ],

        const SizedBox(height: Sp.md),
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
          for (final TravelRow r in outline.rows) _row(context, r),

        if (!plan.hasTimetable) ...<Widget>[
          const SizedBox(height: Sp.sm),
          Text(
            'Bez jízdního řádu — časy jsou odhad ze vzdálenosti, ne konkrétní '
            'spoj.',
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.error),
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

  Widget _row(BuildContext context, TravelRow r) => switch (r) {
        StopRow() => _StopLine(stop: r),
        RideRow() => _RideLine(item: r.item),
        LinkRow() => _LinkLine(text: r.text),
      };

  /// Čas, podle kterého se hledá. Když si ho nikdo nenastavil, ukáže se ten,
  /// který z plánu vyšel — prázdné pole by nutilo hádat, co se stane.
  DateTime? _primaryValue(TripPlan plan, TravelOutline o, Duration off) {
    if (_homeward) {
      return plan.homeBy == null
          ? o.localEnd
          : PlanItem.wallClockOf(plan.homeBy!, off);
    }
    return plan.departAfter == null
        ? o.localStart
        : PlanItem.wallClockOf(plan.departAfter!, off);
  }

  void _setPrimary(WidgetRef ref, DateTime local) {
    _controller(ref).apply(
      _homeward ? SetHomeBy(local) : SetDepartAfter(local),
    );
  }

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

Future<DateTime?> _pickTime(BuildContext context, DateTime? seed) async {
  final DateTime base = seed ?? DateTime.now();
  final TimeOfDay? picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: base.hour, minute: base.minute),
  );
  if (picked == null) return null;
  return DateTime(
    base.year,
    base.month,
    base.day,
    picked.hour,
    picked.minute,
  );
}

/// Čas se šipkami. Půlhodinový krok je kompromis, který se dá zmáčknout
/// palcem a přitom se s ním dá dojet — na minutu se klepne na hodnotu.
class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final bool enabled;
  final ValueChanged<DateTime> onChanged;

  static const Duration _step = Duration(minutes: 30);

  @override
  Widget build(BuildContext context) {
    final DateTime? v = value;
    return Row(
      children: <Widget>[
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: 'O půl hodiny dřív',
          onPressed:
              enabled && v != null ? () => onChanged(v.subtract(_step)) : null,
        ),
        Expanded(
          child: InkWell(
            borderRadius: Radii.inputAll,
            onTap: enabled
                ? () async {
                    final DateTime? picked = await _pickTime(context, v);
                    if (picked != null) onChanged(picked);
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.xs),
              child: Column(
                children: <Widget>[
                  Text(
                    label,
                    style: context.texts.labelSmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                  Text(
                    v == null ? '—:—' : formatClock(v),
                    style: context.texts.titleLarge,
                  ),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: 'O půl hodiny později',
          onPressed: enabled && v != null ? () => onChanged(v.add(_step)) : null,
        ),
      ],
    );
  }
}

class _StopLine extends StatelessWidget {
  const _StopLine({required this.stop});

  final StopRow stop;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 46,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                if (stop.arrival case final DateTime a)
                  Text(
                    formatClock(a),
                    style: context.texts.labelSmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                if (stop.departure case final DateTime d)
                  Text(formatClock(d), style: context.texts.labelLarge),
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
          const SizedBox(width: 46),
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
          const SizedBox(width: 46),
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
