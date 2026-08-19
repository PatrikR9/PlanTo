import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/format/cs_format.dart';
import '../../domain/trip.dart';

class TripCard extends StatelessWidget {
  const TripCard({required this.trip, required this.onTap, super.key});

  final Trip trip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DateFormat fmt = DateFormat('d. M.', 'cs');

    return PtCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              // Ikona, ne vlastní oddíl v seznamu. Dva seznamy znamenají dvě
              // prázdné obrazovky u někoho, kdo zatím používá jen jedno.
              if (trip.isMeeting) ...<Widget>[
                Icon(
                  Icons.groups_outlined,
                  size: 18,
                  color: context.colors.onSurfaceVariant,
                ),
                const SizedBox(width: Sp.xxs),
              ],
              Expanded(
                child: Text(
                  trip.title,
                  style: context.texts.headlineSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _StatusChip(status: trip.status),
            ],
          ),
          const SizedBox(height: Sp.xxs),
          Text(
            <String>[
              if (!trip.isMeeting && trip.originLabel.isNotEmpty)
                trip.originLabel,
              formatDuration(trip.durationMinutes),
              '${fmt.format(trip.windowStart)} – '
                  '${fmt.format(lastDayOfWindow(trip.windowEnd))}',
            ].join(' · '),
            style: context.texts.bodyMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Sp.sm),
          // The most useful line on the card: what is blocking progress.
          _NextAction(trip: trip),
        ],
      ),
    );
  }
}

class _NextAction extends StatelessWidget {
  const _NextAction({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final int waiting = trip.awaitingCalendarCount;
    final bool decided = trip.status == TripStatus.dateLocked ||
        trip.status == TripStatus.confirmed;

    late final IconData icon;
    late final String label;
    late final Color colour;

    if (decided) {
      icon = Icons.event_available;
      label = 'Termín potvrzen';
      colour = context.planto.availabilityFull;
    } else if (trip.participantCount <= 1) {
      icon = Icons.person_add_alt;
      label = 'Pozvěte ostatní';
      colour = context.colors.onSurfaceVariant;
    } else if (waiting > 0) {
      icon = Icons.hourglass_empty;
      label = 'Čekáme na $waiting z ${trip.participantCount}';
      colour = context.planto.weatherFair;
    } else {
      icon = Icons.auto_awesome;
      label = 'Termíny jsou připravené';
      colour = context.planto.availabilityFull;
    }

    return Row(
      children: <Widget>[
        Icon(icon, size: 16, color: colour),
        const SizedBox(width: Sp.xxs),
        Flexible(
          child: Text(
            label,
            style: context.texts.labelSmall?.copyWith(color: colour),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final TripStatus status;

  @override
  Widget build(BuildContext context) {
    final String label = switch (status) {
      TripStatus.draft => 'Koncept',
      TripStatus.planning => 'Plánuje se',
      TripStatus.dateLocked => 'Termín',
      TripStatus.confirmed => 'Potvrzeno',
      TripStatus.completed => 'Hotovo',
      TripStatus.cancelled => 'Zrušeno',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.xs, vertical: 2),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: Radii.pillAll,
      ),
      child: Text(label, style: context.texts.labelSmall),
    );
  }
}
