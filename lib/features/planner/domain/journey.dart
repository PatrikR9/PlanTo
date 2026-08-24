/// Spojení tak, jak o něm ví PlanTo — ne tak, jak ho popsal poskytovatel.
///
/// Tenhle soubor je hranice. Nad ním nikdo neví, že existuje Transitous nebo
/// MOTIS; jméno pole `routeShortName` se sem nedostane. Výměna poskytovatele
/// je pak práce v Edge Function `transport-search` a v [JourneyLeg.fromWire],
/// ne refaktoring celé aplikace.
///
/// Časy jsou tu dvakrát a je to schválně. [JourneyLeg.departure] je okamžik —
/// to, s čím se počítá, řadí a porovnává. [JourneyLeg.localDeparture] jsou
/// nástěnné hodiny v zóně výletu, tedy to, co se ukazuje. Klient nemá tz
/// databázi a `toLocal()` na zařízení běžícím v UTC posune celý plán o dvě
/// hodiny — chyba, kterou tenhle projekt už jednou zaplatil (migrace
/// 20260821140000).
library;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

/// Druh dopravy jednoho úseku.
///
/// `wire` je kontrakt s Edge Function, ne `.name`: přejmenování konstanty
/// v Dartu nesmí tiše rozbít parsování. Stejné pravidlo jako u [StopMode].
enum TransitMode {
  walk('walk'),
  train('train'),
  metro('metro'),
  tram('tram'),
  trolleybus('trolleybus'),
  bus('bus'),
  ferry('ferry'),
  funicular('funicular'),
  cablecar('cablecar'),
  car('car'),
  other('other');

  const TransitMode(this.wire);

  final String wire;

  static TransitMode fromWire(String? v) =>
      TransitMode.values.firstWhereOrNull((TransitMode m) => m.wire == v) ??
      TransitMode.other;

  bool get isWalk => this == TransitMode.walk;
}

/// Nakolik se dá věřit ceně.
enum FareConfidence {
  high('high'),
  medium('medium'),
  rough('rough');

  const FareConfidence(this.wire);

  final String wire;

  static FareConfidence fromWire(String? v) =>
      FareConfidence.values
          .firstWhereOrNull((FareConfidence c) => c.wire == v) ??
      FareConfidence.rough;
}

/// Jízdné jako rozpětí. Nikdy jako jedno číslo.
///
/// Přesné jízdné české veřejné dopravy zadarmo nevydává nikdo, takže
/// [isEstimate] je konstanta a ne pole — je to připomínka pro UI, ne otázka.
/// Kdyby někdy přišla přesná cena z důvěryhodného zdroje, přibude vedle
/// tohohle typu druhý; přepnout `true` na `false` by znamenalo, že se odhad
/// od ceny nepozná podle typu.
@immutable
class FareEstimate {
  const FareEstimate({
    required this.min,
    required this.max,
    required this.currency,
    required this.confidence,
    this.basis = const <String>[],
  });

  final double min;
  final double max;
  final String currency;
  final FareConfidence confidence;

  /// Z čeho odhad vznikl, po úsecích. Bez toho se nedá zjistit, proč vyšlo
  /// 340 Kč — a číslo, které nejde rozebrat, se nedá ani opravit.
  final List<String> basis;

  bool get isEstimate => true;

  /// True, když jsou oba konce tak blízko, že rozpětí je šum.
  bool get isFlat => (max - min).abs() < 1;

  static FareEstimate? fromWire(Map<String, dynamic>? r) {
    if (r == null) return null;
    final double? min = (r['min'] as num?)?.toDouble();
    final double? max = (r['max'] as num?)?.toDouble();
    if (min == null || max == null) return null;
    return FareEstimate(
      min: min,
      max: max,
      currency: (r['currency'] as String?) ?? 'CZK',
      confidence: FareConfidence.fromWire(r['confidence'] as String?),
      basis:
          (r['basis'] as List<dynamic>? ?? const <dynamic>[]).cast<String>(),
    );
  }

  Map<String, dynamic> toWire() => <String, dynamic>{
        'min': min,
        'max': max,
        'currency': currency,
        'confidence': confidence.wire,
        'is_estimate': true,
        'basis': basis,
      };
}

/// Jeden úsek cesty: jízda nebo chůze.
@immutable
class JourneyLeg {
  const JourneyLeg({
    required this.mode,
    required this.fromName,
    required this.toName,
    required this.departure,
    required this.arrival,
    required this.localDeparture,
    required this.localArrival,
    required this.durationMinutes,
    this.operatorName,
    this.lineName,
    this.headsign,
    this.platform,
    this.tripId,
    this.fromStopId,
    this.toStopId,
    this.distanceMeters,
    this.intermediateStops,
    this.intermediateStopNames = const <String>[],
    this.scheduledDeparture,
    this.scheduledArrival,
    this.isRealTime = false,
  });

  final TransitMode mode;

  /// Dopravce („České dráhy"). Null, když ho feed neuvádí.
  final String? operatorName;

  /// Označení linky tak, jak je na ceduli: „R 640", „340", „C".
  final String? lineName;

  /// Kam spoj jede. To, podle čeho se pozná správný nástup na peronu.
  final String? headsign;

  /// Aktuální nástupiště, ne plánované — člověk stojí na tom prvním.
  final String? platform;
  final String? tripId;

  final String fromName;
  final String toName;
  final String? fromStopId;
  final String? toStopId;

  /// Okamžiky. S nimi se počítá.
  final DateTime departure;
  final DateTime arrival;

  /// Nástěnné hodiny v zóně výletu. Ty se ukazují.
  final DateTime localDeparture;
  final DateTime localArrival;

  final int durationMinutes;
  final int? distanceMeters;
  final int? intermediateStops;
  final List<String> intermediateStopNames;

  /// Jízdní řád. Rozdíl proti [departure] je zpoždění.
  final DateTime? scheduledDeparture;
  final DateTime? scheduledArrival;
  final bool isRealTime;

  bool get isWalk => mode.isWalk;

  /// Zpoždění v minutách, nebo null když ho neznáme.
  ///
  /// Null a nula nejsou totéž: nula je „jede včas", null je „nevíme".
  int? get delayMinutes {
    final DateTime? s = scheduledArrival;
    if (s == null || !isRealTime) return null;
    return arrival.difference(s).inMinutes;
  }

  Duration get duration => Duration(minutes: durationMinutes);

  static JourneyLeg fromWire(Map<String, dynamic> r) {
    final DateTime dep = DateTime.parse(r['departure'] as String);
    final DateTime arr = DateTime.parse(r['arrival'] as String);
    return JourneyLeg(
      mode: TransitMode.fromWire(r['mode'] as String?),
      operatorName: _text(r['operator']),
      lineName: _text(r['line']),
      headsign: _text(r['headsign']),
      platform: _text(r['platform']),
      tripId: _text(r['trip_id']),
      fromName: (r['from'] as String?) ?? '',
      toName: (r['to'] as String?) ?? '',
      fromStopId: _text(r['from_stop_id']),
      toStopId: _text(r['to_stop_id']),
      departure: dep,
      arrival: arr,
      localDeparture: localOr(r['local_departure'] as String?, dep),
      localArrival: localOr(r['local_arrival'] as String?, arr),
      durationMinutes: (r['duration_minutes'] as num?)?.toInt() ??
          arr.difference(dep).inMinutes,
      distanceMeters: (r['distance_meters'] as num?)?.toInt(),
      intermediateStops: (r['intermediate_stops'] as num?)?.toInt(),
      intermediateStopNames:
          (r['intermediate_stop_names'] as List<dynamic>? ?? const <dynamic>[])
              .cast<String>(),
      scheduledDeparture: _instant(r['scheduled_departure'] as String?),
      scheduledArrival: _instant(r['scheduled_arrival'] as String?),
      isRealTime: (r['real_time'] as bool?) ?? false,
    );
  }

  /// Do `itinerary_items.detail`. Je to náš model, ne odpověď poskytovatele —
  /// proto se dá uložit a po roce načíst i po výměně vyhledávače.
  Map<String, dynamic> toWire() => <String, dynamic>{
        'mode': mode.wire,
        'operator': operatorName,
        'line': lineName,
        'headsign': headsign,
        'platform': platform,
        'trip_id': tripId,
        'from': fromName,
        'to': toName,
        'from_stop_id': fromStopId,
        'to_stop_id': toStopId,
        'departure': departure.toUtc().toIso8601String(),
        'arrival': arrival.toUtc().toIso8601String(),
        'local_departure': _naive(localDeparture),
        'local_arrival': _naive(localArrival),
        'duration_minutes': durationMinutes,
        'distance_meters': distanceMeters,
        'intermediate_stops': intermediateStops,
        'intermediate_stop_names': intermediateStopNames,
        'scheduled_departure': scheduledDeparture?.toUtc().toIso8601String(),
        'scheduled_arrival': scheduledArrival?.toUtc().toIso8601String(),
        'real_time': isRealTime,
      };
}

/// Celá cesta z A do B, jedna varianta.
@immutable
class Journey {
  const Journey({
    required this.id,
    required this.departure,
    required this.arrival,
    required this.localDeparture,
    required this.localArrival,
    required this.durationMinutes,
    required this.transfers,
    required this.walkMinutes,
    required this.legs,
    this.fare,
    this.co2Kg,
    this.deepLink,
    this.score = 0,
    this.reasonCodes = const <String>[],
  });

  /// Odvozené z časů a linek, ne náhodné. Náhodné ID znamená, že se po
  /// refreshi považuje stejný spoj za jiný a seznam pod prstem přeskočí.
  final String id;

  final DateTime departure;
  final DateTime arrival;
  final DateTime localDeparture;
  final DateTime localArrival;

  final int durationMinutes;
  final int transfers;
  final int walkMinutes;
  final List<JourneyLeg> legs;

  final FareEstimate? fare;
  final double? co2Kg;

  /// Odkaz ven na koupi jízdenky. IDOS — jediný, jehož formát je stabilní.
  final String? deepLink;

  final double score;
  final List<String> reasonCodes;

  Duration get duration => Duration(minutes: durationMinutes);

  List<JourneyLeg> get transitLegs =>
      legs.where((JourneyLeg l) => !l.isWalk).toList();

  /// Čekání mezi jednotlivými jízdami, v pořadí přestupů.
  ///
  /// Počítá se, nepřenáší: je to rozdíl dvou časů, které už máme, a druhé
  /// číslo o téže věci je jenom příležitost, aby se ta dvě rozešla.
  List<Duration> get transferWaits {
    final List<JourneyLeg> transit = transitLegs;
    return <Duration>[
      for (int i = 1; i < transit.length; i++)
        transit[i].departure.difference(transit[i - 1].arrival),
    ];
  }

  bool get isDirect => transfers == 0;

  static Journey fromWire(Map<String, dynamic> r) {
    final DateTime dep = DateTime.parse(r['departure'] as String);
    final DateTime arr = DateTime.parse(r['arrival'] as String);
    return Journey(
      id: r['id'] as String,
      departure: dep,
      arrival: arr,
      localDeparture: localOr(r['local_departure'] as String?, dep),
      localArrival: localOr(r['local_arrival'] as String?, arr),
      durationMinutes: (r['duration_minutes'] as num?)?.toInt() ??
          arr.difference(dep).inMinutes,
      transfers: (r['transfers'] as num?)?.toInt() ?? 0,
      walkMinutes: (r['walk_minutes'] as num?)?.toInt() ?? 0,
      legs: <JourneyLeg>[
        for (final Object? l in (r['legs'] as List<dynamic>? ?? const <dynamic>[]))
          JourneyLeg.fromWire(l! as Map<String, dynamic>),
      ],
      fare: FareEstimate.fromWire(r['fare'] as Map<String, dynamic>?),
      co2Kg: (r['co2_kg'] as num?)?.toDouble(),
      deepLink: _text(r['deep_link']),
      score: ((r['ranking'] as Map<String, dynamic>?)?['score'] as num?)
              ?.toDouble() ??
          0,
      reasonCodes: ((r['ranking'] as Map<String, dynamic>?)?['reason_codes']
                  as List<dynamic>? ??
              const <dynamic>[])
          .cast<String>(),
    );
  }
}

/// Odpověď vyhledávače. Nese i to, čím se odpověď nesmí tvářit.
@immutable
class JourneySearch {
  const JourneySearch({
    required this.journeys,
    required this.provider,
    required this.hasTimetable,
    this.attribution,
    this.providerError,
    this.bestId,
    this.cached = false,
  });

  const JourneySearch.empty()
      : journeys = const <Journey>[],
        provider = 'estimate',
        hasTimetable = false,
        attribution = null,
        providerError = null,
        bestId = null,
        cached = false;

  final List<Journey> journeys;

  /// Kdo odpověděl. `estimate` znamená geometrii bez jízdního řádu.
  final String provider;

  /// False = časy jsou odhad, ne jízdní řád. UI to musí říct nahlas.
  final bool hasTimetable;

  /// Transitous vyžaduje viditelnou atribuci zdrojů. Text jde s odpovědí,
  /// takže se nedá zapnout poskytovatel a zapomenout na ni.
  final String? attribution;

  /// Proč poskytovatel neodpověděl, když neodpověděl. „Časy jsou odhad" je
  /// jiná věta než „časy jsou odhad, protože vyhledávač spadl".
  final String? providerError;

  final String? bestId;
  final bool cached;

  bool get isEmpty => journeys.isEmpty;

  Journey? get best =>
      journeys.firstWhereOrNull((Journey j) => j.id == bestId) ??
      journeys.firstOrNull;

  static JourneySearch fromWire(Map<String, dynamic> r) => JourneySearch(
        journeys: <Journey>[
          for (final Object? o
              in (r['options'] as List<dynamic>? ?? const <dynamic>[]))
            Journey.fromWire(o! as Map<String, dynamic>),
        ],
        provider: (r['provider'] as String?) ?? 'estimate',
        hasTimetable: (r['has_timetable'] as bool?) ?? false,
        attribution: _text(r['attribution']),
        providerError: _text(r['provider_error']),
        bestId: (r['picks'] as Map<String, dynamic>?)?['best'] as String?,
        cached: (r['cached'] as bool?) ?? false,
      );
}

// ---------------------------------------------------------------------------
// Pomocné
// ---------------------------------------------------------------------------

/// Naivní místní čas ze serveru, nebo nouzově okamžik převedený do zóny
/// telefonu.
///
/// Fallback je horší, ne rozbitý: bez `local_*` ukáže aplikace čas v zóně
/// zařízení. To je správně pro člověka, který sedí doma, a o dvě hodiny vedle
/// na emulátoru v UTC — proto je to nouzová větev a ne výchozí cesta.
@visibleForTesting
DateTime localOr(String? local, DateTime instant) {
  if (local != null && local.isNotEmpty) {
    final DateTime? parsed = DateTime.tryParse(local);
    // `DateTime.parse` na řetězci bez offsetu vrátí naivní čas — přesně to,
    // co chceme. Když by v něm offset náhodou byl, je to jiný kontrakt a
    // radši se použije fallback.
    if (parsed != null && !parsed.isUtc) return parsed;
  }
  final DateTime l = instant.toLocal();
  return DateTime(l.year, l.month, l.day, l.hour, l.minute, l.second);
}

String _naive(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}T'
    '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}:'
    '${d.second.toString().padLeft(2, '0')}';

String? _text(Object? v) {
  final String s = v?.toString().trim() ?? '';
  return s.isEmpty ? null : s;
}

DateTime? _instant(String? v) =>
    v == null || v.isEmpty ? null : DateTime.tryParse(v);
