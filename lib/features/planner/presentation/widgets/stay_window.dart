import 'package:flutter/material.dart';

import '../../../../core/design_system/components/components.dart';
import '../../domain/plan_item.dart';
import '../../domain/trip_plan.dart';
import '../plan_strings.dart';

/// Kolik času skupina stráví v cíli — a možnost to změnit.
///
/// Tohle je to hlavní číslo prostřední části. Odjezd zpátky z něj plyne, ne
/// naopak: skupina ví, že chce na místě strávit den a půl, a spoj domů se má
/// hledat podle toho. Proto se tu nastavuje délka pobytu a nikoli „být doma
/// do…" — to je až důsledek, který si člověk musí dopočítat.
class StayWindow extends StatelessWidget {
  const StayWindow({
    required this.plan,
    required this.lastDay,
    required this.enabled,
    required this.onLeaveAt,
    super.key,
  });

  final TripPlan plan;

  /// Poslední den termínu. Rozhoduje o tom, jestli se u odjezdu vybírá i den:
  /// u jednodenního výletu je datum navíc otázka, na kterou je jen jedna
  /// odpověď.
  final DateTime? lastDay;

  final bool enabled;

  /// Naivní místní čas odjezdu zpátky.
  final ValueChanged<DateTime> onLeaveAt;

  static const Duration _step = Duration(minutes: 30);

  @override
  Widget build(BuildContext context) {
    final Duration off = plan.zoneOffset;
    final DateTime? arrival = plan.lastOutbound?.localEnd;
    final DateTime? leave = plan.leaveAt == null
        ? plan.firstHomeward?.localStart
        : PlanItem.wallClockOf(plan.leaveAt!, off);

    final Duration? span =
        arrival == null || leave == null || !leave.isAfter(arrival)
            ? null
            : leave.difference(arrival);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text('Na místě', style: context.texts.labelLarge)),
            if (span != null)
              Text(
                formatSpan(span.inMinutes),
                style: context.texts.labelLarge
                    ?.copyWith(color: context.colors.primary),
              ),
          ],
        ),
        if (arrival != null && leave != null)
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${clockWithDay(arrival, plan.planDate)} – '
                  '${clockWithDay(leave, plan.planDate)}',
                  style: context.texts.bodyMedium,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                tooltip: 'Vyrazit zpátky o půl hodiny dřív',
                onPressed: enabled && leave.subtract(_step).isAfter(arrival)
                    ? () => onLeaveAt(leave.subtract(_step))
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                tooltip: 'Zůstat o půl hodiny déle',
                onPressed: enabled ? () => onLeaveAt(leave.add(_step)) : null,
              ),
              IconButton(
                icon: const Icon(Icons.edit_calendar_outlined),
                tooltip: 'Zadat čas odjezdu zpátky',
                onPressed: enabled ? () => _pick(context, leave) : null,
              ),
            ],
          ),
      ],
    );
  }

  /// Přesný čas odjezdu. U vícedenního výletu se nejdřív vybírá den —
  /// „v 17:00" bez dne je u dvoudenního výletu dvojznačné a hádat, který
  /// z nich člověk myslel, je horší než se zeptat.
  Future<void> _pick(BuildContext context, DateTime seed) async {
    DateTime day = DateTime(seed.year, seed.month, seed.day);
    final DateTime? first = plan.planDate;
    final DateTime? last = lastDay;

    if (first != null && last != null && !_sameDayOf(first, last)) {
      final DateTime? picked = await showDatePicker(
        context: context,
        // Sevřít do rozsahu, ne spolehnout se na data: showDatePicker na
        // initialDate mimo rozsah spadne na assertu, a je to přesně ten
        // případ, který nastane po přesunutí termínu.
        initialDate:
            day.isBefore(first) ? first : (day.isAfter(last) ? last : day),
        firstDate: first,
        lastDate: last,
        helpText: 'Který den vyrazíte zpátky?',
      );
      if (picked == null || !context.mounted) return;
      day = DateTime(picked.year, picked.month, picked.day);
    }

    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: seed.hour, minute: seed.minute),
      helpText: 'V kolik vyrazíte zpátky?',
    );
    if (time == null) return;
    onLeaveAt(DateTime(day.year, day.month, day.day, time.hour, time.minute));
  }
}

bool _sameDayOf(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
