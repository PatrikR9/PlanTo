import 'package:flutter/foundation.dart';

enum TransportMode {
  car('car'),
  public('public');

  const TransportMode(this.wire);

  final String wire;

  static TransportMode fromWire(String? v) =>
      v == 'car' ? TransportMode.car : TransportMode.public;
}

/// One way of getting there, estimated.
///
/// Every field is an estimate and the UI must say so. There is no timetable
/// behind this: a real itinerary needs a routing engine, and the only free
/// one covering CZ/SK/AT/DE/PL is a community service with no commercial
/// licence. MOTIS gets self-hosted at first revenue and fills this same
/// shape, so nothing above this class changes when it does.
@immutable
class TransportOption {
  const TransportOption({
    required this.mode,
    required this.distanceKm,
    required this.duration,
    required this.costMin,
    required this.costMax,
    required this.perPerson,
  });

  final TransportMode mode;

  /// Road or rail distance, not the crow-flies figure the database started
  /// from — the multiplier is applied server-side.
  final double distanceKm;
  final Duration duration;

  final double costMin;
  final double costMax;

  /// Public transport is priced per head; a car is priced per car and the
  /// server has already divided it. Saying which is which is the difference
  /// between "240 Kč" meaning the trip and meaning your share of it.
  final bool perPerson;

  static TransportOption fromRow(Map<String, dynamic> r) => TransportOption(
        mode: TransportMode.fromWire(r['mode'] as String?),
        distanceKm: ((r['distance_km'] as num?) ?? 0).toDouble(),
        duration: Duration(minutes: (r['duration_min'] as num?)?.toInt() ?? 0),
        costMin: ((r['cost_min_czk'] as num?) ?? 0).toDouble(),
        costMax: ((r['cost_max_czk'] as num?) ?? 0).toDouble(),
        perPerson: (r['per_person'] as bool?) ?? true,
      );
}
