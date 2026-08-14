import 'trip.dart';

/// Everything M2 needs. Deliberately small — methods get added when a screen
/// needs them, not in anticipation.
abstract interface class TripRepository {
  Future<List<Trip>> myTrips();
  Future<Trip> byId(String id);
  Future<String> create(NewTrip draft);

  /// Patch, ne replace: mapa nese jen změněná pole. Klíč s null maže.
  /// Prázdná mapa se nikam neposílá — viz [TripDraft.patchFrom].
  Future<void> update(String id, Map<String, Object?> patch);
}

/// The creation payload, separate from [Trip] because a trip that does not
/// exist yet has no id, status or participants. Modelling them as nullable on
/// one class would push those null checks into every screen.
class NewTrip {
  const NewTrip({
    required this.title,
    required this.windowStart,
    required this.windowEnd,
    required this.durationMinutes,
    required this.transport,
    this.kind = TripKind.trip,
    this.originLabel,
    this.originLat,
    this.originLon,
    this.originPlaceId,
    this.slotStepMinutes = 30,
    this.dayStart = const Duration(hours: 7),
    this.dayEnd = const Duration(hours: 21),
    this.description,
    this.budgetPerPerson,
    this.activityTags = const <ActivityTag>[],
    this.earliestWake,
    this.currency = 'CZK',
  });

  final TripKind kind;
  final String title;
  final String? description;

  /// Nullable od M13: setkání nemá odkud vyjet. U výletu je server odmítne
  /// založit bez původu, takže tahle volnost nesahá na výlety.
  final String? originLabel;
  final double? originLat;
  final double? originLon;

  /// Vybraná zastávka. Souřadnice se posílají i tak: server z nich založí
  /// výlet ve chvíli, kdy je databáze zastávek ještě prázdná, a bez toho by
  /// mezi migrací a prvním importem nešlo založit nic.
  final String? originPlaceId;
  final DateTime windowStart;
  final DateTime windowEnd;

  /// Jediné pole o délce. Granularitu i počet dní si server odvodí sám.
  final int durationMinutes;
  final TransportPref transport;
  final int slotStepMinutes;
  final Duration dayStart;
  final Duration dayEnd;
  final double? budgetPerPerson;
  final List<ActivityTag> activityTags;
  final Duration? earliestWake;
  final String currency;
}
