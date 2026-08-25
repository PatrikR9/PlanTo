import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/error/failure.dart';
import '../../../trips/domain/trip.dart';
import '../../../trips/presentation/controllers/trip_invalidation.dart';
import '../../data/transport_repository.dart';
import '../../domain/transit_stop.dart';
import '../../domain/transport_option.dart';
import 'stop_picker_sheet.dart';

/// Cíl výletu jako pole nastavení.
///
/// Od M15 bydlí v nastavení výletu, ne v plánu. Na plánu překážel: je to
/// rozhodnutí, které se udělá jednou na začátku, a stálo nad časovou osou,
/// kterou člověk otvírá pokaždé.
class DestinationCard extends ConsumerWidget {
  const DestinationCard({required this.trip, super.key});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? where = trip.destinationFree;
    final bool canEdit = trip.isOrganiser;

    return PtCard(
      onTap: canEdit
          ? () => pickDestination(context, ref, trip.id, near: originOf(trip))
          : null,
      child: Row(
        children: <Widget>[
          const Icon(Icons.place_outlined),
          const SizedBox(width: Sp.sm),
          Expanded(
            child: Text(
              where == null || where.isEmpty
                  ? 'Vyberte zastávku nebo místo'
                  : where,
              style: context.texts.bodyLarge,
            ),
          ),
          if (canEdit) const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

/// Výlet zatím nemá kam jet.
class NoDestinationView extends ConsumerWidget {
  const NoDestinationView({required this.trip, super.key});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PtEmptyState(
      title: 'Kam pojedete?',
      message: trip.isOrganiser
          ? 'Cíl se zadává v nastavení výletu. Jakmile tam bude, sestavíme '
              'plán cesty i s časy spojů.'
          : 'Organizátor zatím nevybral cíl. Až ho vybere, uvidíte tady '
              'celý plán výletu.',
      icon: Icons.place_outlined,
      actionLabel: trip.isOrganiser ? 'Otevřít nastavení' : null,
      onAction: trip.isOrganiser
          ? () => context.push(Routes.editTrip(trip.id))
          : null,
    );
  }
}

/// Srovnání „veřejnou dopravou versus autem" z geometrického modelu.
///
/// Zůstává vedle časové osy schválně: osa říká, jak se jede veřejnou
/// dopravou, tahle karta říká, jestli se to vůbec vyplatí proti autu. Jsou to
/// dvě různé otázky a odpověď na tu druhou by se zrušením karty zmizela.
class TransportComparisonCard extends ConsumerWidget {
  const TransportComparisonCard({required this.trip, super.key});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<TransportOption>> options =
        ref.watch(transportOptionsProvider(trip.id));
    final List<TransportOption>? list = options.valueOrNull;
    if (list == null || list.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Srovnání variant', style: context.texts.labelLarge),
        const SizedBox(height: Sp.xs),
        for (final TransportOption o in list) ...<Widget>[
          _OptionCard(option: o, trip: trip),
          const SizedBox(height: Sp.xs),
        ],
      ],
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
                  isCar ? 'Autem' : 'Veřejnou dopravou',
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

/// Vybere cíl a přepočítá, co na něm visí.
///
/// Od M7 to je skutečná zastávka, ne položka z ručně psaného seznamu:
/// uživatel si vybere „Špindlerův Mlýn, Hromovka" a ne jenom „Špindlerův
/// Mlýn". Uloží se ID zastávky, ne řetězec — teprve z něj se dá zeptat na
/// spojení.
Future<void> pickDestination(
  BuildContext context,
  WidgetRef ref,
  String tripId, {
  ({double lat, double lon})? near,
}) async {
  final TransitStop? picked = await pickTransitStop(
    context,
    title: 'Kam pojedete?',
    hint: 'Špindlerův Mlýn',
    near: near,
  );
  if (picked == null || !context.mounted) return;

  try {
    await ref.read(transportRepositoryProvider).setDestinationStop(
          tripId,
          picked.id,
        );
    // Na cíli visí odhad dopravy, odhad ceny, hlavička výletu i celý plán.
    // Vyjmenovávat to tady znovu je způsob, jak na jedno z toho zapomenout —
    // seznam odvozených providerů je na jednom místě schválně.
    invalidateTripDerivedFromWidget(ref, tripId);
  } on Failure catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(errorText(e))));
  }
}

/// Výchozí bod výletu jako kotva pro řazení zastávek.
///
/// Není to poloha uživatele — tu aplikace nemá a kvůli řazení si o ni říkat
/// nebude. Je to lepší přiblížení, než žádné: kdo jede z Ostravy, hledá
/// obvykle něco, kam se z Ostravy dá dojet.
({double lat, double lon}) originOf(Trip trip) =>
    (lat: trip.originLat, lon: trip.originLon);
