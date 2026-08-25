import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../costs/data/cost_repository.dart';
import '../../../dates/data/date_repository.dart';
import '../../../packing/presentation/packing_controller.dart';
import '../../../planner/presentation/plan_controller.dart';
import '../../../transport/data/transport_repository.dart';
import 'trips_controller.dart';

/// Všechno, co se z výletu odvozuje, na jednom místě.
///
/// Termíny, plán, náklady i balení jsou čtecí funkce nad `trips` — po každé
/// změně výletu jsou zastaralé současně. Rozepsané po voláních to znamená, že
/// příští přidaná záložka se zapomene na jednom ze tří míst a projeví se to
/// jako pláštěnka v seznamu na den, na který se už nejede.
///
/// Záměrně sahá do datové vrstvy cizích features: providery jsou jejich
/// veřejné rozhraní a alternativa — nechat invalidaci na widgetech — by ji
/// rozdrobila přesně tak, jak tenhle soubor má zabránit.
void invalidateTripDerived(Ref ref, String tripId) {
  ref
    ..invalidate(tripProvider(tripId))
    ..invalidate(myTripsProvider)
    ..invalidate(dateCandidatesProvider(tripId))
    ..invalidate(transportOptionsProvider(tripId))
    ..invalidate(costEstimateProvider(tripId))
    ..invalidate(packingControllerProvider(tripId))
    ..invalidate(planControllerProvider(tripId));
}
