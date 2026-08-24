import 'package:flutter/material.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/format/cs_format.dart';
import '../../domain/journey.dart';

/// Seznam spojů k ručnímu výběru.
///
/// Vybraný spoj se v plánu **zamkne** a označí jako uživatelova volba —
/// automatický přepočet ho pak nesmí vyměnit potichu. To je celý smysl téhle
/// obrazovky: dát člověku možnost říct „tenhle, a ten mi neměňte".
Future<Journey?> showJourneySheet(
  BuildContext context, {
  required String title,
  required Future<JourneySearch> search,
}) {
  return showModalBottomSheet<Journey>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
    builder: (BuildContext context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (BuildContext context, ScrollController controller) =>
          _JourneyList(title: title, search: search, controller: controller),
    ),
  );
}

class _JourneyList extends StatelessWidget {
  const _JourneyList({
    required this.title,
    required this.search,
    required this.controller,
  });

  final String title;
  final Future<JourneySearch> search;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<JourneySearch>(
      future: search,
      builder: (BuildContext context, AsyncSnapshot<JourneySearch> snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(Sp.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                PtSkeleton(height: 84),
                SizedBox(height: Sp.xs),
                PtSkeleton(height: 84),
                SizedBox(height: Sp.xs),
                PtSkeleton(height: 84),
              ],
            ),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(Sp.lg),
            child: PtErrorState(message: errorText(snap.error)),
          );
        }

        final JourneySearch result = snap.data ?? const JourneySearch.empty();
        if (result.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(Sp.lg),
            child: PtEmptyState(
              title: 'Žádný spoj',
              // Nikdy nepředstírat, že trasa existuje. Prázdný výsledek je
              // odpověď, ne chyba k obejití.
              message: 'Pro tenhle čas vyhledávač nenašel žádné spojení. '
                  'Zkuste jiný čas odjezdu.',
              icon: Icons.train,
            ),
          );
        }

        return ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(Sp.lg, 0, Sp.lg, Sp.xl),
          children: <Widget>[
            Text(title, style: context.texts.titleMedium),
            const SizedBox(height: Sp.xs),
            if (!result.hasTimetable)
              Padding(
                padding: const EdgeInsets.only(bottom: Sp.xs),
                child: Text(
                  'Bez jízdního řádu — časy jsou odhad ze vzdálenosti.',
                  style: context.texts.labelSmall
                      ?.copyWith(color: context.colors.error),
                ),
              ),
            for (final Journey j in result.journeys) ...<Widget>[
              _JourneyCard(
                journey: j,
                isBest: j.id == result.bestId,
                onTap: () => Navigator.of(context).pop(j),
              ),
              const SizedBox(height: Sp.xs),
            ],
            if (result.attribution case final String a)
              Padding(
                padding: const EdgeInsets.only(top: Sp.sm),
                child: Text(
                  a,
                  style: context.texts.labelSmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _JourneyCard extends StatelessWidget {
  const _JourneyCard({
    required this.journey,
    required this.isBest,
    required this.onTap,
  });

  final Journey journey;
  final bool isBest;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FareEstimate? fare = journey.fare;

    return PtCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '${formatClock(journey.localDeparture)} → '
                '${formatClock(journey.localArrival)}',
                style: context.texts.titleMedium,
              ),
              const Spacer(),
              Text(
                formatLength(journey.durationMinutes),
                style: context.texts.bodyMedium,
              ),
            ],
          ),
          const SizedBox(height: Sp.xxs),
          Text(
            <String>[
              journey.isDirect
                  ? 'bez přestupu'
                  : '${journey.transfers} × přestup',
              if (journey.walkMinutes > 0) 'pěšky ${journey.walkMinutes} min',
              for (final JourneyLeg l in journey.transitLegs)
                if (l.lineName != null) l.lineName!,
            ].join(' · '),
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          if (fare != null) ...<Widget>[
            const SizedBox(height: Sp.xxs),
            Text(
              // Vždycky „odhad". Přesné jízdné české veřejné dopravy zadarmo
              // nevydává nikdo a tvářit se jinak by bylo to jediné číslo na
              // obrazovce, podle kterého by se někdo zařídil.
              '≈ ${fare.min.round()}–${fare.max.round()} ${fare.currency} '
              '· odhad',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
          if (isBest) ...<Widget>[
            const SizedBox(height: Sp.xxs),
            Text(
              'Doporučeno',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.planto.availabilityFull),
            ),
          ],
        ],
      ),
    );
  }
}
