import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../availability/data/availability_repository.dart';
import '../../../availability/presentation/availability_controller.dart';
import '../../../availability/presentation/screens/connect_calendar_sheet.dart';
import '../../../availability/presentation/widgets/availability_strip.dart';
import '../../../invites/presentation/screens/share_invite_sheet.dart';
import '../../domain/trip.dart';
import '../controllers/trips_controller.dart';

/// Trip shell with inner tabs. Tabs are a query param so a notification can
/// deep-link straight to /trips/:id?tab=dates.
class TripDetailScreen extends ConsumerStatefulWidget {
  const TripDetailScreen({
    required this.tripId,
    this.tab = 'overview',
    super.key,
  });

  final String tripId;
  final String tab;

  @override
  ConsumerState<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends ConsumerState<TripDetailScreen>
    with SingleTickerProviderStateMixin {
  static const List<({String key, String label})> _tabs =
      <({String key, String label})>[
    (key: 'overview', label: 'Přehled'),
    (key: 'dates', label: 'Termíny'),
    (key: 'plan', label: 'Plán'),
    (key: 'costs', label: 'Náklady'),
    (key: 'packing', label: 'Sbalit'),
    (key: 'chat', label: 'Chat'),
  ];

  late final TabController _controller = TabController(
    length: _tabs.length,
    vsync: this,
    initialIndex: _tabs
        .indexWhere((({String key, String label}) t) => t.key == widget.tab)
        .clamp(0, _tabs.length - 1),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<Trip> trip = ref.watch(tripProvider(widget.tripId));

    return Scaffold(
      appBar: AppBar(
        title: Text(trip.valueOrNull?.title ?? 'Výlet'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.person_add_alt),
            tooltip: 'Pozvat',
            onPressed: () => ShareInviteSheet.show(context, widget.tripId),
          ),
        ],
        bottom: TabBar(
          controller: _controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: <Widget>[
            for (final ({String key, String label}) t in _tabs)
              Tab(text: t.label),
          ],
        ),
      ),
      body: AsyncValueView<Trip>(
        value: trip,
        onRetry: () => ref.invalidate(tripProvider(widget.tripId)),
        data: (Trip t) => TabBarView(
          controller: _controller,
          children: <Widget>[
            _Overview(trip: t),
            _Dates(trip: t),
            for (int i = 2; i < _tabs.length; i++)
              Center(child: Text('${_tabs[i].label} — brzy')),
          ],
        ),
      ),
    );
  }
}

class _Overview extends ConsumerWidget {
  const _Overview({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateFormat fmt = DateFormat('d. M. y', 'cs');

    return ListView(
      padding: const EdgeInsets.all(Sp.md),
      children: <Widget>[
        PtCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Kdy by se to hodilo', style: context.texts.labelLarge),
              const SizedBox(height: Sp.xxs),
              Text(
                '${fmt.format(trip.windowStart)} – '
                '${fmt.format(trip.windowEnd)}',
                style: context.texts.bodyLarge,
              ),
              const SizedBox(height: Sp.sm),
              Text('Odjezd z ${trip.originLabel}',
                  style: context.texts.bodyMedium),
            ],
          ),
        ),
        const SizedBox(height: Sp.md),

        // The next-action card. Everything else on this screen is reference;
        // this is the one thing the organiser should do now.
        PtCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Dostupnost', style: context.texts.labelLarge),
              const SizedBox(height: Sp.xxs),
              Text(
                '${trip.calendarSharedCount} z ${trip.participantCount} '
                'sdílelo dostupnost',
                style: context.texts.bodyMedium
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              const SizedBox(height: Sp.md),
              PtButton(
                label: 'Sdílet moji dostupnost',
                expand: true,
                onPressed: () => ConnectCalendarSheet.show(
                  context,
                  tripId: trip.id,
                  windowStart: trip.windowStart,
                  windowEnd: trip.windowEnd,
                ),
              ),
              if (trip.awaitingCalendarCount > 0) ...<Widget>[
                const SizedBox(height: Sp.xs),
                Text(
                  'Čekáme ještě na ${trip.awaitingCalendarCount} '
                  'z ${trip.participantCount}. Pošlete jim odkaz.',
                  style: context.texts.labelSmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Dates extends ConsumerWidget {
  const _Dates({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<DayAvailability>> days =
        ref.watch(availabilityProvider(trip.id));

    return AsyncValueView<List<DayAvailability>>(
      value: days,
      onRetry: () => ref.invalidate(availabilityProvider(trip.id)),
      isEmpty: (List<DayAvailability> d) =>
          d.isEmpty || d.every((DayAvailability x) => x.totalCount == 0),
      empty: () => PtEmptyState(
        title: 'Zatím není co spočítat',
        message: 'Až aspoň dva lidé sdílí dostupnost, '
            'navrhneme termíny automaticky.',
        icon: Icons.calendar_month_outlined,
        actionLabel: 'Sdílet moji dostupnost',
        onAction: () => ConnectCalendarSheet.show(
          context,
          tripId: trip.id,
          windowStart: trip.windowStart,
          windowEnd: trip.windowEnd,
        ),
      ),
      data: (List<DayAvailability> list) {
        final List<DayAvailability> best = <DayAvailability>[...list]..sort(
            (DayAvailability a, DayAvailability b) {
              final int byCount = b.freeCount.compareTo(a.freeCount);
              return byCount != 0 ? byCount : a.day.compareTo(b.day);
            },
          );

        return ListView(
          padding: const EdgeInsets.symmetric(vertical: Sp.md),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.md),
              child: Text('Celé rozmezí', style: context.texts.labelLarge),
            ),
            const SizedBox(height: Sp.xs),
            AvailabilityStrip(days: list),
            const SizedBox(height: Sp.lg),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.md),
              child: Text('Nejlepší dny', style: context.texts.labelLarge),
            ),
            const SizedBox(height: Sp.xs),
            for (final DayAvailability d in best.take(5))
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.md, 0, Sp.md, Sp.xs),
                child: PtCard(
                  child: Row(
                    children: <Widget>[
                      PtScoreRing(
                        score: (d.ratio * 100).round(),
                        semanticLabel:
                            '${d.freeCount} z ${d.totalCount} má volno',
                        size: 44,
                      ),
                      const SizedBox(width: Sp.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              DateFormat('EEEE d. M.', 'cs').format(d.day),
                              style: context.texts.bodyLarge,
                            ),
                            Text(
                              <String>[
                                '${d.freeCount} z ${d.totalCount} volných',
                                if (d.isWeekend) 'víkend',
                                if (d.isHoliday) 'svátek',
                              ].join(' · '),
                              style: context.texts.labelSmall?.copyWith(
                                color: context.colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
