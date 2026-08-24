/// Fakta o výletu, která engine potřebuje — a nic víc.
///
/// Není to `Trip`. Kdyby engine bral celý výlet, nešel by otestovat bez toho,
/// aby si test postavil objekt s třiceti poli, z nichž devětadvacet je mu
/// jedno. Takhle je [PlanContext] zároveň dokumentace toho, na čem plán
/// doopravdy stojí: odkud, kam, který den a jak dlouhý ten den je.
library;

import 'package:flutter/foundation.dart';

import 'plan_item.dart';

/// Místo, ze kterého nebo do kterého se jede.
///
/// [placeId] je zastávka v naší databázi. Souřadnice jsou tu vždycky, protože
/// vyhledávač spojení pracuje s nimi — naše UUID pro něj nic neznamená.
@immutable
class PlanPlace {
  const PlanPlace({
    required this.name,
    required this.lat,
    required this.lon,
    this.placeId,
  });

  final String? placeId;
  final String name;
  final double lat;
  final double lon;

  Map<String, dynamic> toWire() => <String, dynamic>{
        if (placeId != null) 'placeId': placeId,
        'lat': lat,
        'lon': lon,
        'name': name,
      };
}

/// Dotaz na spojení. Vzniká v enginu, odesílá ho datová vrstva.
///
/// [direction] nemění vyhledání, ale je součástí klíče do cache a odpovědi.
/// Cesta zpět **není** obrácená cesta tam: hledá se samostatně, podle svého
/// času a svých podmínek, a tohle pole je to, co tu samostatnost drží
/// viditelnou až do serveru.
@immutable
class JourneyQuery {
  const JourneyQuery({
    required this.origin,
    required this.destination,
    required this.when,
    required this.arriveBy,
    required this.direction,
  });

  final PlanPlace origin;
  final PlanPlace destination;

  /// Okamžik. Podle [arriveBy] je to buď „nejdřív vyraž", nebo „nejpozději
  /// dorazíš".
  final DateTime when;
  final bool arriveBy;
  final PlanSegment direction;

  Map<String, dynamic> toWire(String tripId, {int groupSize = 1}) =>
      <String, dynamic>{
        'tripId': tripId,
        'origin': origin.toWire(),
        'destination': destination.toWire(),
        'departure': when.toUtc().toIso8601String(),
        'arriveBy': arriveBy,
        'direction': direction == PlanSegment.homeward ? 'return' : 'outbound',
        'groupSize': groupSize,
      };

  @override
  bool operator ==(Object other) =>
      other is JourneyQuery &&
      other.origin.lat == origin.lat &&
      other.origin.lon == origin.lon &&
      other.destination.lat == destination.lat &&
      other.destination.lon == destination.lon &&
      other.when == when &&
      other.arriveBy == arriveBy &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(origin.lat, origin.lon, destination.lat,
      destination.lon, when, arriveBy, direction);
}

@immutable
class PlanContext {
  const PlanContext({
    required this.tripId,
    required this.timezone,
    required this.zoneOffset,
    required this.origin,
    required this.destination,
    required this.planDate,
    required this.dayStartLocal,
    required this.dayEndLocal,
    this.groupSize = 1,
    this.transferBuffer = const Duration(minutes: 5),
    this.homeWalk = const Duration(minutes: 10),
    this.settleAfterArrival = const Duration(minutes: 15),
    this.readyBeforeDeparture = const Duration(minutes: 10),
  });

  final String tripId;
  final String timezone;

  /// Posun zóny výletu proti UTC v den výletu. Předává se, ne odvozuje: v den
  /// změny času má den dva offsety a hádat, který platí, je horší než dostat
  /// ten správný ze serveru.
  final Duration zoneOffset;

  final PlanPlace origin;
  final PlanPlace destination;

  /// Naivní datum výletu v zóně výletu.
  final DateTime planDate;

  /// Použitelná část dne — naivní časy v zóně výletu. Bere se z výletu
  /// (`trips.day_start` / `day_end`), protože výšlap za východem slunce a
  /// deskovky do jedenácti nemají stejné okno.
  final DateTime dayStartLocal;
  final DateTime dayEndLocal;

  final int groupSize;

  /// Kolik minut si nechat na přestup navíc nad rámec jízdního řádu. Nula
  /// znamená „věř řádu", což na nádraží s podchodem nefunguje.
  final Duration transferBuffer;

  /// Cesta z domova na první zastávku, dokud neznáme adresu uživatele.
  final Duration homeWalk;

  /// Než se skupina po příjezdu skutečně rozejde za programem.
  final Duration settleAfterArrival;

  /// Než se dojde zpátky na zastávku před odjezdem domů.
  final Duration readyBeforeDeparture;

  /// Ze serveru. Posun zóny se **nepočítá na klientovi** — ten nemá tz
  /// databázi a hádat ho podle zóny telefonu znamená na emulátoru v UTC
  /// hledat spoje o dvě hodiny vedle.
  ///
  /// Vrací null, když se plán postavit nedá: bez zamčeného termínu není na
  /// kdy, bez cíle se souřadnicemi není kam. Obrazovka má na obojí vlastní
  /// stav a rozlišit je umí podle [PlanContextGap].
  static PlanContext? fromWire(Map<String, dynamic> r) {
    final DateTime? date = _date(r['plan_date'] as String?);
    final Map<String, dynamic>? dest =
        (r['destination'] as Map<String, dynamic>?);
    if (date == null || dest == null) return null;

    final Duration offset =
        Duration(minutes: (r['zone_offset_minutes'] as num?)?.toInt() ?? 0);
    return PlanContext(
      tripId: r['trip_id'] as String,
      timezone: (r['timezone'] as String?) ?? 'Europe/Prague',
      zoneOffset: offset,
      origin: _place(r['origin'] as Map<String, dynamic>?) ??
          const PlanPlace(name: 'Odkud', lat: 0, lon: 0),
      destination: _place(dest)!,
      planDate: date,
      dayStartLocal: _at(date, r['day_start'] as String?, 7),
      dayEndLocal: _at(date, r['day_end'] as String?, 21),
      groupSize: (r['group_size'] as num?)?.toInt() ?? 1,
      transferBuffer:
          Duration(minutes: (r['transfer_buffer_min'] as num?)?.toInt() ?? 5),
      homeWalk: Duration(minutes: (r['home_walk_min'] as num?)?.toInt() ?? 10),
    );
  }

  /// Co plánu chybí, když se [fromWire] nepovedlo.
  static PlanContextGap gapOf(Map<String, dynamic>? r) {
    if (r == null) return PlanContextGap.noDate;
    if (_date(r['plan_date'] as String?) == null) return PlanContextGap.noDate;
    if (r['destination'] == null) return PlanContextGap.noDestination;
    return PlanContextGap.none;
  }

  DateTime instant(DateTime wallClock) =>
      PlanItem.instantOf(wallClock, zoneOffset);

  DateTime wallClock(DateTime instant) =>
      PlanItem.wallClockOf(instant, zoneOffset);

  /// Výchozí „nejdřív vyrazím" — začátek použitelného dne.
  DateTime get defaultDepartAfter => instant(dayStartLocal);

  /// Výchozí „být doma nejpozději" — konec použitelného dne.
  DateTime get defaultHomeBy => instant(dayEndLocal);
}

/// Proč se plán zatím nedá postavit.
enum PlanContextGap { none, noDate, noDestination }

PlanPlace? _place(Map<String, dynamic>? r) {
  if (r == null) return null;
  final double? lat = (r['lat'] as num?)?.toDouble();
  final double? lon = (r['lon'] as num?)?.toDouble();
  if (lat == null || lon == null) return null;
  return PlanPlace(
    name: (r['name'] as String?) ?? '',
    lat: lat,
    lon: lon,
    placeId: r['place_id'] as String?,
  );
}

DateTime? _date(String? v) {
  if (v == null || v.isEmpty) return null;
  final DateTime? d = DateTime.tryParse(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

/// `07:00` na daném dni. Fallback je hodina, ne půlnoc: den, který začíná
/// o půlnoci, by poslal skupinu na noční spoj.
DateTime _at(DateTime day, String? hhmm, int fallbackHour) {
  final List<String> parts = (hhmm ?? '').split(':');
  final int h = parts.length >= 2
      ? (int.tryParse(parts[0]) ?? fallbackHour)
      : fallbackHour;
  final int m = parts.length >= 2 ? (int.tryParse(parts[1]) ?? 0) : 0;
  return DateTime(day.year, day.month, day.day, h, m);
}
