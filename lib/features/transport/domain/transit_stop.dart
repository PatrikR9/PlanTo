import 'package:flutter/foundation.dart';

/// Druh dopravy na zastávce.
///
/// `wire` je kontrakt s enumem `stop_mode` v databázi. Serializace přes
/// `.name` je jedno přejmenování od tiché ztráty dat, takže tady je pole
/// explicitně — stejné pravidlo jako u TripGranularity a ActivityTag.
enum StopMode {
  train('train'),
  metro('metro'),
  tram('tram'),
  trolleybus('trolleybus'),
  bus('bus'),
  ferry('ferry'),
  funicular('funicular'),
  cablecar('cablecar'),
  other('other');

  const StopMode(this.wire);

  final String wire;

  static StopMode fromWire(String? v) {
    for (final StopMode m in StopMode.values) {
      if (m.wire == v) return m;
    }
    return StopMode.other;
  }
}

/// Zastávka, nádraží nebo stanice, jak ji uživatel vybírá.
///
/// Není to jeden sloupek. Server sdružuje stejnojmenné zastávky do jednoho
/// místa — „Praha, Florenc" je ve zdrojích osm sloupků a nabídnout osm
/// identických řádků znamená nechat uživatele vybírat mezi věcmi, o kterých
/// nemůže nic vědět. [stopCount] říká, kolik jich pod tím je.
@immutable
class TransitStop {
  const TransitStop({
    required this.id,
    required this.name,
    required this.mode,
    required this.lat,
    required this.lon,
    this.city,
    this.district,
    this.region,
    this.modes = const <StopMode>[],
    this.stopCount = 1,
    this.wheelchair,
    this.distanceKm,
  });

  final String id;
  final String name;

  /// Převažující druh dopravy. Ikona v seznamu.
  final StopMode mode;

  /// Všechno, co tu staví. „Praha hl.n." je vlak i metro.
  final List<StopMode> modes;

  final double lat;
  final double lon;

  /// Obec. Zná ji jenom PID, takže mimo Prahu a Střední Čechy bývá prázdná.
  final String? city;

  /// Okres. To, co odlišuje čtvery Chrášťany.
  final String? district;
  final String? region;

  final int stopCount;

  /// GTFS wheelchair_boarding: 1 ano, 2 ne, null neznámo.
  final int? wheelchair;

  /// Vzdálenost od uživatele. Null, když polohu nemáme — a to je normální
  /// stav, ne chyba: hledání na ní nesmí záviset.
  final double? distanceKm;

  /// Druhý řádek v seznamu. Prázdný raději než opakující se jméno:
  /// „Praha hl.n. / Praha" nese nulovou informaci navíc.
  String get subtitle {
    final List<String> parts = <String>[
      if (city != null && city!.isNotEmpty && city != name) city!,
      if (district != null && district!.isNotEmpty && district != city)
        district!,
    ];
    return parts.join(' · ');
  }

  bool get isAccessible => wheelchair == 1;

  static TransitStop fromRow(Map<String, dynamic> r) => TransitStop(
        id: r['id'] as String,
        name: r['name'] as String,
        mode: StopMode.fromWire(r['mode'] as String?),
        modes: <StopMode>[
          for (final Object? m
              in (r['modes'] as List<dynamic>? ?? const <dynamic>[]))
            StopMode.fromWire(m as String?),
        ],
        lat: ((r['lat'] as num?) ?? 0).toDouble(),
        lon: ((r['lon'] as num?) ?? 0).toDouble(),
        city: r['city'] as String?,
        district: r['district'] as String?,
        region: r['region'] as String?,
        stopCount: (r['stop_count'] as num?)?.toInt() ?? 1,
        wheelchair: (r['wheelchair'] as num?)?.toInt(),
        distanceKm: (r['distance_km'] as num?)?.toDouble(),
      );

  @override
  bool operator ==(Object other) => other is TransitStop && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
