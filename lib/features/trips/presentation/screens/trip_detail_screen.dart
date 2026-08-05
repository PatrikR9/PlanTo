import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../costs/presentation/screens/costs_tab.dart';
import '../../../dates/presentation/screens/dates_tab.dart';
import '../../../invites/presentation/screens/share_invite_sheet.dart';
import '../../../transport/presentation/screens/plan_tab.dart';
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
            DatesTab(trip: t),
            PlanTab(trip: t),
            CostsTab(trip: t),
            // Sbalit (M8) a Chat (M10). Zbytek seznamu, ne pevná čísla —
            // přidání záložky je pak jeden řádek nahoře a nic tady.
            for (int i = 4; i < _tabs.length; i++)
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
              Text(
                'Odjezd z ${trip.originLabel}',
                style: context.texts.bodyMedium,
              ),
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
              // One button, not two. The availability screen offers both the
              // calendar import and hand entry side by side, so making the
              // person choose a path before they have seen either was a
              // decision asked too early.
              PtButton(
                label: 'Sdílet moji dostupnost',
                expand: true,
                onPressed: () => context.push(Routes.availability(trip.id)),
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
