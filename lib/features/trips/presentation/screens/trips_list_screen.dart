import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/entitlement/capabilities.dart';
import '../../domain/trip.dart';
import '../controllers/trips_controller.dart';
import '../widgets/trip_card.dart';

/// Výlet, nebo setkání.
///
/// Sheet, ne dvě tlačítka: rozdíl mezi nimi se dá vysvětlit jednou větou a
/// druhý FAB by ji neunesl. Kdo si vybere setkání, přeskočí tím pět polí.
Future<void> _pickWhatToPlan(BuildContext context) async {
  final String? route = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.hiking_outlined),
            title: const Text('Výlet'),
            subtitle: const Text('Termín, doprava, cena a co si sbalit'),
            onTap: () => Navigator.of(context).pop(Routes.newTripName),
          ),
          ListTile(
            leading: const Icon(Icons.groups_outlined),
            title: const Text('Setkání'),
            subtitle: const Text('Jen společný čas — nic víc se neřeší'),
            onTap: () => Navigator.of(context).pop(Routes.newMeetingName),
          ),
          const SizedBox(height: Sp.sm),
        ],
      ),
    ),
  );

  // pushNamed vrací future, která doběhne až tím, že se založená obrazovka
  // zavře. Čekat na ni znamená držet tuhle funkci naživu po celou dobu
  // zakládání výletu a k ničemu to není — sheet svou práci odvedl výběrem.
  // Explicitní unawaited, ne zahozená hodnota: takhle je vidět, že to je
  // rozhodnutí, a ne opomenutí.
  if (route != null && context.mounted) unawaited(context.pushNamed(route));
}

class TripsListScreen extends ConsumerWidget {
  const TripsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Trip>> trips = ref.watch(myTripsProvider);

    final bool canCreate = ref.watch(canCreateTripProvider);
    final bool isGuest = ref.watch(needsAccountUpgradeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Výlety')),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              onPressed: () => _pickWhatToPlan(context),
              icon: const Icon(Icons.add),
              label: const Text('Naplánovat'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(myTripsProvider.future),
        child: AsyncValueView<List<Trip>>(
          value: trips,
          onRetry: () => ref.invalidate(myTripsProvider),
          isEmpty: (List<Trip> t) => t.isEmpty,
          empty: () => ListView(
            // Must scroll, or RefreshIndicator has nothing to pull.
            physics: const AlwaysScrollableScrollPhysics(),
            children: <Widget>[
              SizedBox(height: MediaQuery.sizeOf(context).height * 0.15),
              // A guest sees an empty list and no create button. Left
              // unexplained that reads as a broken app, so say why and offer
              // the way out instead of just hiding the button.
              PtEmptyState(
                title: isGuest
                    ? 'Jste přihlášeni jako host'
                    : 'Zatím žádné výlety',
                message: isGuest
                    ? 'Hosté se můžou připojit k výletu přes odkaz.\n'
                        'Pro zakládání vlastních výletů se přihlaste.'
                    : 'Založte výlet a pošlete odkaz kamarádům.\n'
                        'Termín najdeme za vás.',
                icon: isGuest ? Icons.person_outline : Icons.hiking_outlined,
                actionLabel: isGuest
                    ? 'Přihlásit se'
                    : (canCreate ? 'Naplánovat něco' : null),
                onAction: isGuest
                    ? () => context.push(Routes.signIn)
                    : (canCreate ? () => _pickWhatToPlan(context) : null),
              ),
            ],
          ),
          data: (List<Trip> list) => ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(Sp.md, Sp.md, Sp.md, Sp.giant),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: Sp.sm),
            itemBuilder: (BuildContext context, int i) => TripCard(
              trip: list[i],
              onTap: () => context.push(Routes.tripDetail(list[i].id)),
            ),
          ),
        ),
      ),
    );
  }
}
