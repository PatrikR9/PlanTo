import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/error/failure.dart';
import '../../../costs/data/cost_repository.dart';
import '../../../trips/domain/trip.dart';
import '../../../trips/presentation/controllers/trips_controller.dart';
import '../../data/transport_repository.dart';
import '../../domain/destinations.dart';
import '../../domain/transport_option.dart';

/// The Plan tab: how the group gets there, and what it costs.
///
/// Everything on this screen is an estimate and says so. There is no
/// timetable behind it — a real itinerary needs a routing engine, and the
/// only free one covering this region is a community service with no
/// commercial licence. So the numbers come from geometry and a fare model,
/// and the departure time comes from IDOS, which is where a Czech person was
/// going to look anyway.
///
/// The alternative was inventing a departure. "Odjezd 7:14" that is not a
/// real train is worse than no departure at all: it is the one number on the
/// screen somebody would act on.
class PlanTab extends ConsumerWidget {
  const PlanTab({required this.trip, super.key});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!trip.hasDestination) {
      return _NoDestination(trip: trip);
    }

    final AsyncValue<List<TransportOption>> options =
        ref.watch(transportOptionsProvider(trip.id));

    return AsyncValueView<List<TransportOption>>(
      value: options,
      onRetry: () => ref.invalidate(transportOptionsProvider(trip.id)),
      isEmpty: (List<TransportOption> o) => o.isEmpty,
      empty: () => _NoDestination(trip: trip),
      data: (List<TransportOption> list) => ListView(
        padding: const EdgeInsets.all(Sp.md),
        children: <Widget>[
          _DestinationCard(trip: trip),
          const SizedBox(height: Sp.lg),
          Text('Jak se tam dostat', style: context.texts.labelLarge),
          const SizedBox(height: Sp.xs),
          for (final TransportOption o in list) ...<Widget>[
            _OptionCard(option: o, trip: trip),
            const SizedBox(height: Sp.xs),
          ],
          const SizedBox(height: Sp.sm),
          Container(
            padding: const EdgeInsets.all(Sp.sm),
            decoration: BoxDecoration(
              color: context.colors.surfaceContainerHighest,
              borderRadius: Radii.inputAll,
            ),
            child: Text(
              'Časy a ceny jsou odhad ze vzdálenosti a průměrných tarifů — '
              'ne z jízdního řádu. Konkrétní spoj a cenu najdete v IDOS.',
              style: context.texts.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _DestinationCard extends ConsumerWidget {
  const _DestinationCard({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PtCard(
      child: Row(
        children: <Widget>[
          Icon(Icons.place_outlined, color: context.planto.availabilityFull),
          const SizedBox(width: Sp.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${trip.originLabel} → ${trip.destinationFree}',
                  style: context.texts.titleMedium,
                ),
                Text(
                  'Cíl výletu',
                  style: context.texts.labelSmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (trip.isOrganiser)
            PtButton(
              label: 'Změnit',
              variant: PtButtonVariant.text,
              onPressed: () => pickDestination(context, ref, trip.id),
            ),
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({required this.option, required this.trip});

  final TransportOption option;
  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final bool isCar = option.mode == TransportMode.car;

    return PtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                isCar ? Icons.directions_car_outlined : Icons.train_outlined,
                color: context.colors.primary,
              ),
              const SizedBox(width: Sp.sm),
              Expanded(
                child: Text(
                  isCar ? 'Autem' : 'Vlakem nebo autobusem',
                  style: context.texts.titleMedium,
                ),
              ),
              Text(
                // Approximately, and it looks approximate. A "2 h 08 min"
                // from a model with no timetable would be a lie told with a
                // straight face.
                '≈ ${_duration(option.duration)}',
                style: context.texts.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: Sp.xxs),
          Text(
            <String>[
              '${option.distanceKm.round()} km',
              '≈ ${option.costMin.round()}–${option.costMax.round()} Kč'
                  '${option.perPerson ? " / osoba" : " / osoba v autě"}',
              'odhad',
            ].join(' · '),
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Sp.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: PtButton(
              label: isCar ? 'Otevřít v mapách' : 'Najít spoj v IDOS',
              variant: PtButtonVariant.text,
              icon: Icons.open_in_new,
              onPressed: () => _open(
                isCar
                    ? _mapsUrl(trip.originLabel, trip.destinationFree ?? '')
                    : _idosUrl(trip.originLabel, trip.destinationFree ?? ''),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Future<void> _open(Uri url) async {
    // externalApplication so it lands in the IDOS or Maps app if it is
    // installed. Silently ignoring a failure is right here: the worst case is
    // a button that did nothing, and there is no recovery to offer.
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  static Uri _idosUrl(String from, String to) => Uri.https(
        'idos.cz',
        '/vlakyautobusymhdvse/spojeni/',
        <String, String>{'f': from, 't': to},
      );

  static Uri _mapsUrl(String from, String to) => Uri.https(
        'www.google.com',
        '/maps/dir/',
        <String, String>{
          'api': '1',
          'origin': from,
          'destination': to,
          'travelmode': 'driving',
        },
      );

  static String _duration(Duration d) {
    final int h = d.inHours;
    final int m = d.inMinutes % 60;
    if (h == 0) return '$m min';
    return m == 0 ? '$h h' : '$h h $m min';
  }
}

class _NoDestination extends ConsumerWidget {
  const _NoDestination({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(Sp.xl),
      children: <Widget>[
        const SizedBox(height: Sp.xxl),
        PtEmptyState(
          title: 'Kam pojedete?',
          message: trip.isOrganiser
              ? 'Vyberte cíl a spočítáme, jak dlouho to trvá a co to bude '
                  'stát.'
              : 'Organizátor zatím nevybral cíl. Až ho vybere, uvidíte tady '
                  'cestu i odhad ceny.',
          icon: Icons.place_outlined,
          actionLabel: trip.isOrganiser ? 'Vybrat cíl' : null,
          onAction: trip.isOrganiser
              ? () => pickDestination(context, ref, trip.id)
              : null,
        ),
      ],
    );
  }
}

/// Pick a destination, then recompute.
///
/// A list rather than a search box because there is no geocoder: Nominatim's
/// usage policy forbids exactly this kind of interactive lookup, and MOTIS
/// brings its own the day it is self-hosted.
Future<void> pickDestination(
  BuildContext context,
  WidgetRef ref,
  String tripId,
) async {
  final TripDestination? picked = await showModalBottomSheet<TripDestination>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _DestinationSheet(),
  );
  if (picked == null || !context.mounted) return;

  try {
    await ref.read(transportRepositoryProvider).setDestination(
          tripId,
          label: picked.name,
          lat: picked.lat,
          lon: picked.lon,
        );
    ref
      ..invalidate(transportOptionsProvider(tripId))
      // The cost estimate is built on top of the transport one, so it is
      // wrong by the same amount and in the same instant.
      ..invalidate(costEstimateProvider(tripId))
      // The trip header shows the destination too, so it is stale the moment
      // this succeeds.
      ..invalidate(tripProvider(tripId))
      ..invalidate(myTripsProvider);
  } on Failure catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(errorText(e))));
  }
}

class _DestinationSheet extends StatefulWidget {
  const _DestinationSheet();

  @override
  State<_DestinationSheet> createState() => _DestinationSheetState();
}

class _DestinationSheetState extends State<_DestinationSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final List<TripDestination> matches = kDestinations
        .where(
          (TripDestination d) =>
              _query.isEmpty ||
              d.name.toLowerCase().contains(_query.toLowerCase()) ||
              d.region.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();

    return Padding(
      padding: EdgeInsets.only(
        left: Sp.xl,
        right: Sp.xl,
        top: Sp.md,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Sp.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Kam pojedete?', style: context.texts.titleLarge),
          const SizedBox(height: Sp.sm),
          TextField(
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Hledat'),
            onChanged: (String v) => setState(() => _query = v),
          ),
          const SizedBox(height: Sp.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: matches.length,
              itemBuilder: (BuildContext context, int i) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(matches[i].name),
                subtitle: Text(matches[i].region),
                onTap: () => Navigator.of(context).pop(matches[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
