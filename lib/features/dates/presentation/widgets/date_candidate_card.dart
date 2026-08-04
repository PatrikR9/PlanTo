import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/format/cs_format.dart';
import '../../domain/date_candidate.dart';
import 'weather_glyph.dart';

/// One proposed termín.
///
/// The ring shows availability, not the composite score. The score decides
/// the order; availability is the number a person can check against their own
/// knowledge of the group, and showing a figure nobody can verify is how an
/// app loses trust in one screen.
class DateCandidateCard extends StatelessWidget {
  const DateCandidateCard({
    required this.candidate,
    required this.timed,
    required this.onVote,
    this.isBest = false,
    this.onLock,
    this.onUnlock,
    this.busy = false,
    super.key,
  });

  final DateCandidate candidate;

  /// Time mode. Changes the headline from a date to a clock range; everything
  /// else about the card is identical, which is the point of the shared
  /// candidate model.
  final bool timed;

  /// Highest ranked by the engine. The list itself is in time order, so this
  /// is where the ranking lives now — one badge instead of a running order
  /// nobody could follow.
  final bool isBest;

  /// Null withdraws the current vote.
  final void Function(DateVote? vote) onVote;

  /// Organiser-only. Null for everyone else, which is what hides the control.
  final VoidCallback? onLock;
  final VoidCallback? onUnlock;

  final bool busy;

  @override
  Widget build(BuildContext context) {
    final DateCandidate c = candidate;

    final Color accent = c.everyoneFree
        ? context.planto.availabilityFull
        : c.freeCount == 0
            ? context.planto.availabilityNone
            : context.planto.availabilityPartial;

    return PtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              PtScoreRing(
                score: c.availabilityPercent,
                semanticLabel: '${c.freeCount} z ${c.totalCount} má volno',
                size: 48,
              ),
              const SizedBox(width: Sp.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(_headline(c, timed), style: context.texts.titleMedium),
                    const SizedBox(height: Sp.xxs),
                    Text(
                      _subtitle(c, timed),
                      style: context.texts.labelSmall
                          ?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (c.isLocked)
                Semantics(
                  label: 'Zamknutý termín',
                  child: Icon(Icons.lock_outline, color: accent, size: 20),
                )
              else if (isBest)
                Semantics(
                  label: 'Nejlepší návrh',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Sp.xs,
                      vertical: Sp.xxs,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: Radii.pillAll,
                    ),
                    child: Text(
                      'Nejlepší',
                      style: context.texts.labelSmall?.copyWith(color: accent),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: Sp.xs),
          _WeatherLine(candidate: c, timed: timed),
          const SizedBox(height: Sp.sm),

          // emptySelectionAllowed is what makes "I misclicked" recoverable:
          // tapping the selected answer again withdraws the vote.
          SegmentedButton<DateVote>(
            segments: const <ButtonSegment<DateVote>>[
              ButtonSegment<DateVote>(
                value: DateVote.yes,
                label: Text('Můžu'),
                icon: Icon(Icons.check),
              ),
              ButtonSegment<DateVote>(
                value: DateVote.maybe,
                label: Text('Možná'),
                icon: Icon(Icons.help_outline),
              ),
              ButtonSegment<DateVote>(
                value: DateVote.no,
                label: Text('Nemůžu'),
                icon: Icon(Icons.close),
              ),
            ],
            selected: <DateVote>{if (c.myVote != null) c.myVote!},
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            onSelectionChanged: busy
                ? null
                : (Set<DateVote> selection) =>
                    onVote(selection.isEmpty ? null : selection.first),
          ),

          if (c.votesCast > 0) ...<Widget>[
            const SizedBox(height: Sp.xs),
            Text(
              _tally(c),
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],

          if (onLock != null || onUnlock != null) ...<Widget>[
            const SizedBox(height: Sp.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: c.isLocked
                  ? PtButton(
                      label: 'Odemknout',
                      variant: PtButtonVariant.text,
                      icon: Icons.lock_open_outlined,
                      onPressed: busy ? null : onUnlock,
                    )
                  : PtButton(
                      label: 'Zamknout tenhle termín',
                      variant: PtButtonVariant.text,
                      icon: Icons.lock_outline,
                      onPressed: busy ? null : onLock,
                    ),
            ),
          ],
        ],
      ),
    );
  }

  /// Time mode leads with the clock, because that is the decision. Day mode
  /// leads with the weekday, for the same reason.
  static String _headline(DateCandidate c, bool timed) {
    if (timed) {
      return '${formatWallClock(_since(c.startsAt))} – '
          '${formatWallClock(_since(c.endsAt))}';
    }
    final String start =
        capitalise(DateFormat('EEEE d. M.', 'cs').format(c.startsAt));
    // endsAt is exclusive, so a trip that ends on the 14th has endsAt on the
    // 15th. Showing the exclusive bound sends people home a day late.
    final DateTime lastDay = c.endsAt.subtract(const Duration(days: 1));
    if (!lastDay.isAfter(c.startsAt)) return start;
    return '$start – ${DateFormat('EEEE d. M.', 'cs').format(lastDay)}';
  }

  static String _subtitle(DateCandidate c, bool timed) {
    return <String>[
      if (timed) capitalise(DateFormat('EEEE d. M.', 'cs').format(c.startsAt)),
      '${c.freeCount} z ${c.totalCount} volných',
      if (timed && c.hasSlack)
        'volno až do ${formatWallClock(_since(c.windowEndsAt))}',
      if (c.isWeekend) 'víkend',
      if (c.isHoliday) 'svátek',
    ].join(' · ');
  }

  /// Wall-clock time of an instant, as a Duration since local midnight.
  static Duration _since(DateTime t) =>
      Duration(hours: t.hour, minutes: t.minute);

  static String _tally(DateCandidate c) {
    return <String>[
      if (c.yesCount > 0) '${c.yesCount}× můžu',
      if (c.maybeCount > 0) '${c.maybeCount}× možná',
      if (c.noCount > 0) '${c.noCount}× nemůžu',
    ].join(' · ');
  }
}

/// The forecast, or an honest statement that there isn't one.
///
/// "Předpověď zatím není" is information. A grey zero would be a lie, and it
/// is also not what the ranking did — the score renormalises its weights when
/// the forecast is missing rather than treating unknown as bad.
class _WeatherLine extends StatelessWidget {
  const _WeatherLine({required this.candidate, required this.timed});

  final DateCandidate candidate;
  final bool timed;

  @override
  Widget build(BuildContext context) {
    final DateCandidate c = candidate;

    if (!c.hasWeather) {
      return Row(
        children: <Widget>[
          Icon(
            Icons.schedule,
            size: 14,
            color: context.colors.onSurfaceVariant,
          ),
          const SizedBox(width: Sp.xxs),
          Expanded(
            child: Text(
              'Předpověď zatím není — je to víc než 16 dní dopředu',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
        ],
      );
    }

    final int score = c.weatherScore!;
    final Color colour = context.planto.weatherForScore(score);

    final List<String> parts = <String>[
      wmoLabel(c.weatherCode),
      if (c.tempMax != null) '${c.tempMax!.round()} °C',
      if ((c.precipProb ?? 0) >= 20) '${c.precipProb} % déšť',
    ];

    final List<String> warnings = <String>[
      if (c.weatherIsStormy) 'bouřka',
      if ((c.windGustKmh ?? 0) >= 60) 'nárazový vítr',
      // User story D4. Only meaningful when there is a clock to compare
      // against, which day mode does not have.
      if (timed && c.endsAfterDark) 'skončí po setmění',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(wmoIcon(c.weatherCode), size: 16, color: colour),
            const SizedBox(width: Sp.xxs),
            Expanded(
              child: Text(
                // The number is shown next to the words that produced it, so
                // a person can disagree with it for a reason.
                '$score/100 · ${parts.join(' · ')}',
                style: context.texts.labelSmall?.copyWith(color: colour),
              ),
            ),
          ],
        ),
        if (warnings.isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.xxs),
          Row(
            children: <Widget>[
              Icon(
                Icons.warning_amber_outlined,
                size: 14,
                color: context.planto.weatherSevere,
              ),
              const SizedBox(width: Sp.xxs),
              Expanded(
                child: Text(
                  warnings.join(' · '),
                  style: context.texts.labelSmall
                      ?.copyWith(color: context.planto.weatherSevere),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
