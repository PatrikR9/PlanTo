import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/format/cs_format.dart';
import '../../../availability/data/availability_repository.dart';
import '../../../availability/presentation/widgets/availability_strip.dart';
import '../../../trips/domain/trip.dart';
import '../../data/date_repository.dart';
import '../../domain/date_candidate.dart';
import '../dates_controller.dart';
import '../widgets/date_candidate_card.dart';

/// The Dates tab — where the group actually decides.
///
/// Order matters: the answer first, the chores last. The heat strip shows the
/// shape of the whole window at a glance, then the ranked candidates with
/// voting, then the nudge for whoever has not replied.
///
/// In time mode candidates are grouped under a day heading, because several
/// slots can land on the same Thursday and a flat list of clock times reads
/// as noise. In day mode there is exactly one candidate per day, so a heading
/// above each would be pure decoration.
class DatesTab extends ConsumerWidget {
  const DatesTab({required this.trip, super.key});

  final Trip trip;

  Future<void> _mutate(
    BuildContext context,
    WidgetRef ref,
    Future<bool> Function() action,
  ) async {
    final bool ok = await action();
    if (ok) return;
    if (!context.mounted) return;

    final Object? error = ref.read(datesControllerProvider).error;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            errorText(error),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<DateCandidate>> candidates =
        ref.watch(dateCandidatesProvider(trip.id));
    final AsyncValue<List<DayAvailability>> strip =
        ref.watch(availabilityProvider(trip.id));
    final bool busy = ref.watch(datesControllerProvider).isLoading;

    // Nobody has answered yet, so every day would show as "everyone free" —
    // technically what the solver returns (an unknown schedule is treated as
    // free) and completely misleading as a proposal. Ask first.
    if (trip.calendarSharedCount == 0) {
      return _NothingYet(trip: trip);
    }

    return RefreshIndicator(
      onRefresh: () async {
        ref
          ..invalidate(dateCandidatesProvider(trip.id))
          ..invalidate(availabilityProvider(trip.id));
      },
      child: AsyncValueView<List<DateCandidate>>(
        value: candidates,
        onRetry: () => ref.invalidate(dateCandidatesProvider(trip.id)),
        isEmpty: (List<DateCandidate> c) => c.isEmpty,
        empty: () => _NothingYet(trip: trip),
        data: (List<DateCandidate> list) => _CandidateList(
          trip: trip,
          candidates: list,
          strip: strip.valueOrNull ?? const <DayAvailability>[],
          busy: busy,
          onVote: (DateCandidate c, DateVote? v) => _mutate(
            context,
            ref,
            () => ref.read(datesControllerProvider.notifier).vote(
                  tripId: trip.id,
                  startsAt: c.startsAt,
                  vote: v,
                ),
          ),
          onLock: (DateCandidate c) => _mutate(
            context,
            ref,
            () => ref
                .read(datesControllerProvider.notifier)
                .lock(tripId: trip.id, startsAt: c.startsAt),
          ),
          onUnlock: () => _mutate(
            context,
            ref,
            () => ref.read(datesControllerProvider.notifier).unlock(
                  tripId: trip.id,
                ),
          ),
        ),
      ),
    );
  }
}

class _CandidateList extends StatelessWidget {
  const _CandidateList({
    required this.trip,
    required this.candidates,
    required this.strip,
    required this.busy,
    required this.onVote,
    required this.onLock,
    required this.onUnlock,
  });

  final Trip trip;
  final List<DateCandidate> candidates;
  final List<DayAvailability> strip;
  final bool busy;
  final void Function(DateCandidate candidate, DateVote? vote) onVote;
  final void Function(DateCandidate candidate) onLock;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    // Built once per rebuild rather than inside the item builder, so grouping
    // is not recomputed for every visible card.
    final List<Widget> rows = _rows(context);

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: Sp.xxl),
      itemCount: rows.length,
      itemBuilder: (BuildContext context, int i) => rows[i],
    );
  }

  List<Widget> _rows(BuildContext context) {
    final DateFormat dayFmt = DateFormat('EEEE d. M.', 'cs');
    final List<Widget> out = <Widget>[];

    // The server ranks by score; the screen shows time order.
    //
    // Those are different jobs. A list that jumps 12 Sep, 3 Nov, 19 Sep is
    // sorted correctly and reads as noise — people scan dates the way a
    // calendar does. So the ranking survives as a badge on the single best
    // candidate rather than as the order of the list, and nothing is lost:
    // the score was never the thing being compared, the days were.
    final DateTime? bestStart =
        candidates.isEmpty ? null : candidates.first.startsAt;
    final List<DateCandidate> byTime = <DateCandidate>[...candidates]..sort(
        (DateCandidate a, DateCandidate b) => a.startsAt.compareTo(b.startsAt),
      );

    if (trip.isDateLocked) {
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.md, Sp.md, Sp.md, 0),
          child: _LockedBanner(trip: trip),
        ),
      );
    }
    if (trip.awaitingCalendarCount > 0) {
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.md, Sp.md, Sp.md, 0),
          child: _WaitingBanner(count: trip.awaitingCalendarCount),
        ),
      );
    }

    out
      ..add(const SizedBox(height: Sp.md))
      ..add(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Sp.md),
          child: _SectionLabel('Celé rozmezí'),
        ),
      )
      ..add(const SizedBox(height: Sp.xs))
      ..add(AvailabilityStrip(days: strip))
      ..add(const SizedBox(height: Sp.lg))
      ..add(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Sp.md),
          child: _SectionLabel('Návrhy termínů'),
        ),
      )
      ..add(const SizedBox(height: Sp.xs));

    DateTime? lastDay;
    for (final DateCandidate c in byTime) {
      if (trip.isTimed && c.day != lastDay) {
        lastDay = c.day;
        out.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.md, Sp.xs, Sp.md, Sp.xxs),
            child: Text(
              capitalise(dayFmt.format(c.day)),
              style: context.texts.labelLarge
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
        );
      }
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.md, 0, Sp.md, Sp.xs),
          child: DateCandidateCard(
            // The key keeps element state (and the segmented button's ripple)
            // attached to the right candidate when the list reorders after a
            // vote.
            key: ValueKey<DateTime>(c.startsAt),
            candidate: c,
            timed: trip.isTimed,
            busy: busy,
            onVote: (DateVote? v) => onVote(c, v),
            onLock: trip.isOrganiser ? () => onLock(c) : null,
            onUnlock: trip.isOrganiser ? onUnlock : null,
          ),
        ),
      );
    }

    out
      ..add(const SizedBox(height: Sp.md))
      ..add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.md),
          child: PtButton(
            label: 'Upravit moji dostupnost',
            variant: PtButtonVariant.text,
            icon: Icons.edit_calendar_outlined,
            expand: true,
            onPressed: () => context.push(Routes.availability(trip.id)),
          ),
        ),
      );

    return out;
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: context.texts.labelLarge);
}

class _NothingYet extends StatelessWidget {
  const _NothingYet({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(Sp.xl),
      children: <Widget>[
        const SizedBox(height: Sp.xxl),
        PtEmptyState(
          title: 'Zatím není co spočítat',
          message: 'Řekněte nám, kdy nemůžete — z kalendáře nebo ručně — '
              'a navrhneme termíny, které sednou celé skupině.',
          icon: Icons.calendar_month_outlined,
          actionLabel: 'Zadat dostupnost',
          onAction: () => context.push(Routes.availability(trip.id)),
        ),
      ],
    );
  }
}

class _LockedBanner extends StatelessWidget {
  const _LockedBanner({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final DateTime start = trip.lockedStart!;
    final DateTime? end = trip.lockedEnd;

    final String when;
    if (trip.isTimed) {
      final String dayLabel =
          capitalise(DateFormat('EEEE d. M.', 'cs').format(start));
      final String from = formatWallClock(
        Duration(hours: start.hour, minutes: start.minute),
      );
      final String to = end == null
          ? ''
          : ' – ${formatWallClock(
              Duration(hours: end.hour, minutes: end.minute),
            )}';
      when = '$dayLabel, $from$to';
    } else {
      // locked_range is half-open, so the last day of the trip is end - 1.
      // Showing the exclusive bound would tell people to come home a day late.
      final DateTime? lastDay = end?.subtract(const Duration(days: 1));
      final DateFormat fmt = DateFormat('EEEE d. M. y', 'cs');
      when = lastDay != null && lastDay.isAfter(start)
          ? '${capitalise(fmt.format(start))} – ${fmt.format(lastDay)}'
          : capitalise(fmt.format(start));
    }

    return PtCard(
      child: Row(
        children: <Widget>[
          Icon(Icons.event_available, color: context.planto.availabilityFull),
          const SizedBox(width: Sp.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Termín je domluvený', style: context.texts.labelLarge),
                const SizedBox(height: Sp.xxs),
                Text(when, style: context.texts.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WaitingBanner extends StatelessWidget {
  const _WaitingBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Sp.sm),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: Radii.inputAll,
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.hourglass_empty,
            size: 18,
            color: context.colors.onSurfaceVariant,
          ),
          const SizedBox(width: Sp.xs),
          Expanded(
            child: Text(
              // Three plural forms, and this is why nothing user-visible is
              // stored as a finished sentence (architecture section 20).
              switch (count) {
                1 => 'Čekáme ještě na 1 člověka — návrhy se můžou změnit.',
                2 ||
                3 ||
                4 =>
                  'Čekáme ještě na $count lidi — návrhy se můžou změnit.',
                _ => 'Čekáme ještě na $count lidí — návrhy se můžou změnit.',
              },
              style: context.texts.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}
