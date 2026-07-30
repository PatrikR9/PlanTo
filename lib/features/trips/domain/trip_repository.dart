import 'trip.dart';

/// Everything M2 needs. Deliberately small — methods get added when a screen
/// needs them, not in anticipation.
abstract interface class TripRepository {
  Future<List<Trip>> myTrips();
  Future<Trip> byId(String id);
  Future<String> create(NewTrip draft);
}

/// The creation payload, separate from [Trip] because a trip that does not
/// exist yet has no id, status or participants. Modelling them as nullable on
/// one class would push those null checks into every screen.
class NewTrip {
  const NewTrip({
    required this.title,
    required this.originLabel,
    required this.originLat,
    required this.originLon,
    required this.windowStart,
    required this.windowEnd,
    required this.durationDays,
    required this.transport,
    this.description,
    this.budgetPerPerson,
    this.activityTags = const <ActivityTag>[],
    this.earliestWake,
    this.currency = 'CZK',
  });

  final String title;
  final String? description;
  final String originLabel;
  final double originLat;
  final double originLon;
  final DateTime windowStart;
  final DateTime windowEnd;
  final int durationDays;
  final TransportPref transport;
  final double? budgetPerPerson;
  final List<ActivityTag> activityTags;
  final Duration? earliestWake;
  final String currency;
}
