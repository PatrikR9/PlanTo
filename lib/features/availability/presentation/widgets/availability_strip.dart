import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/design_system/components/components.dart';
import '../../data/availability_repository.dart';

/// Horizontal calendar band where colour intensity is how many people are
/// free. One of the three signature elements (architecture section 7.1).
///
/// Colour is never the only signal: every cell also carries the fraction as
/// text and a full sentence in its semantics label.
class AvailabilityStrip extends StatelessWidget {
  const AvailabilityStrip({
    required this.days,
    this.onDayTap,
    this.selected,
    super.key,
  });

  final List<DayAvailability> days;
  final void Function(DayAvailability day)? onDayTap;
  final DateTime? selected;

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const SizedBox.shrink();

    final DateFormat dayFmt = DateFormat('E', 'cs');
    final DateFormat numFmt = DateFormat('d.M.', 'cs');

    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Sp.md),
        itemCount: days.length,
        separatorBuilder: (_, __) => const SizedBox(width: Sp.xs),
        itemBuilder: (BuildContext context, int i) {
          final DayAvailability d = days[i];
          final bool isSelected = selected != null &&
              selected!.year == d.day.year &&
              selected!.month == d.day.month &&
              selected!.day == d.day.day;

          final Color base = d.everyoneFree
              ? context.planto.availabilityFull
              : d.freeCount == 0
                  ? context.planto.availabilityNone
                  : context.planto.availabilityPartial;

          return Semantics(
            button: onDayTap != null,
            selected: isSelected,
            label: '${numFmt.format(d.day)}: '
                '${d.freeCount} z ${d.totalCount} má volno'
                '${d.isHoliday ? ", svátek" : ""}',
            excludeSemantics: true,
            child: InkWell(
              onTap: onDayTap == null ? null : () => onDayTap!(d),
              borderRadius: Radii.cardAll,
              child: Container(
                width: 64,
                padding: const EdgeInsets.all(Sp.xs),
                decoration: BoxDecoration(
                  color: base.withValues(alpha: d.everyoneFree ? 0.22 : 0.14),
                  borderRadius: Radii.cardAll,
                  border: Border.all(
                    color: isSelected ? base : context.planto.hairline,
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      dayFmt.format(d.day),
                      style: context.texts.labelSmall?.copyWith(
                        color: d.isWeekend || d.isHoliday
                            ? context.colors.primary
                            : context.colors.onSurfaceVariant,
                      ),
                    ),
                    Text(numFmt.format(d.day), style: context.texts.labelLarge),
                    const SizedBox(height: Sp.xxs),
                    Text(
                      '${d.freeCount}/${d.totalCount}',
                      style: context.texts.labelSmall?.copyWith(color: base),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
