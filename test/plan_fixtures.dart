/// Testovací data pro plánovač.
///
/// Časy jsou psané jako **místní** (Praha, letní čas, +2). Okamžik se z nich
/// odvozuje odečtením dvou hodin, ne přes `toLocal()` — jinak by testy
/// vycházely jinak na stroji v Berlíně a jinak v CI běžící v UTC.
library;

import 'package:planto/features/planner/domain/journey.dart';
import 'package:planto/features/planner/domain/plan_context.dart';

const Duration kTestOffset = Duration(hours: 2);

/// Naivní místní čas 12. 9. 2026.
DateTime wall(int hour, int minute) => DateTime(2026, 9, 12, hour, minute);

/// Tentýž okamžik jako UTC ISO.
String isoOf(int hour, int minute) => DateTime.utc(2026, 9, 12, hour, minute)
    .subtract(kTestOffset)
    .toIso8601String();

/// Nástěnné hodiny jako naivní ISO, přesně jak je posílá server.
String naiveOf(int hour, int minute) =>
    '2026-09-12T${_two(hour)}:${_two(minute)}:00';

String _two(int n) => n.toString().padLeft(2, '0');

Map<String, dynamic> legWire({
  required String mode,
  required String from,
  required String to,
  required int depH,
  required int depM,
  required int arrH,
  required int arrM,
  String? line,
  String? operatorName,
  String? platform,
  int? distanceMeters,
  List<String> intermediate = const <String>[],
  bool realTime = false,
  int? scheduledArrH,
  int? scheduledArrM,
}) {
  final int duration = (arrH * 60 + arrM) - (depH * 60 + depM);
  return <String, dynamic>{
    'mode': mode,
    'operator': operatorName,
    'line': line,
    'headsign': to,
    'from': from,
    'to': to,
    'from_stop_id': null,
    'to_stop_id': null,
    'departure': isoOf(depH, depM),
    'arrival': isoOf(arrH, arrM),
    'local_departure': naiveOf(depH, depM),
    'local_arrival': naiveOf(arrH, arrM),
    'scheduled_departure': null,
    'scheduled_arrival':
        scheduledArrH == null ? null : isoOf(scheduledArrH, scheduledArrM ?? 0),
    'real_time': realTime,
    'duration_minutes': duration,
    'distance_meters': distanceMeters,
    'platform': platform,
    'trip_id': line == null ? null : 'trip-$line',
    'route_id': null,
    'intermediate_stops': intermediate.isEmpty ? null : intermediate.length,
    'intermediate_stop_names': intermediate,
  };
}

Map<String, dynamic> optionWire({
  required String id,
  required List<Map<String, dynamic>> legs,
  required int transfers,
  int walkMinutes = 0,
  Map<String, dynamic>? fare,
}) {
  final Map<String, dynamic> first = legs.first;
  final Map<String, dynamic> last = legs.last;
  final DateTime dep = DateTime.parse(first['departure'] as String);
  final DateTime arr = DateTime.parse(last['arrival'] as String);
  return <String, dynamic>{
    'id': id,
    'mode': legs
        .map((Map<String, dynamic> l) => l['mode'] as String)
        .firstWhere((String m) => m != 'walk', orElse: () => 'walk'),
    'departure': first['departure'],
    'arrival': last['arrival'],
    'local_departure': first['local_departure'],
    'local_arrival': last['local_arrival'],
    'duration_minutes': arr.difference(dep).inMinutes,
    'transfers': transfers,
    'walk_minutes': walkMinutes,
    'legs': legs,
    'fare': fare,
    'co2_kg': 8.4,
    'deep_link': 'https://idos.cz/',
    'ranking': <String, dynamic>{
      'score': 0.82,
      'reason_codes': <String>['LOW_TRANSFERS'],
    },
  };
}

const Map<String, dynamic> kFare = <String, dynamic>{
  'min': 240.0,
  'max': 320.0,
  'currency': 'CZK',
  'confidence': 'medium',
  'is_estimate': true,
  'basis': <String>['train: 200–260 CZK', 'bus: 40–60 CZK'],
};

/// Praha → Český Krumlov, 08:10–10:52, jeden přestup, chůze na začátku.
Map<String, dynamic> outboundWire() => optionWire(
      id: 'out-1',
      transfers: 1,
      walkMinutes: 15,
      fare: kFare,
      legs: <Map<String, dynamic>>[
        legWire(
          mode: 'walk',
          from: 'Domov',
          to: 'Praha hl.n.',
          depH: 8,
          depM: 10,
          arrH: 8,
          arrM: 25,
        ),
        legWire(
          mode: 'train',
          from: 'Praha hl.n.',
          to: 'České Budějovice',
          depH: 8,
          depM: 25,
          arrH: 9,
          arrM: 47,
          line: 'R 640',
          operatorName: 'České dráhy',
          platform: '3',
          distanceMeters: 169000,
          intermediate: <String>['Tábor'],
          realTime: true,
          scheduledArrH: 9,
          scheduledArrM: 45,
        ),
        legWire(
          mode: 'bus',
          from: 'České Budějovice',
          to: 'Český Krumlov',
          depH: 10,
          depM: 1,
          arrH: 10,
          arrM: 52,
          line: '340',
        ),
      ],
    );

/// Přímý spoj bez přestupu, 09:00–11:00.
Map<String, dynamic> directWire() => optionWire(
      id: 'out-direct',
      transfers: 0,
      legs: <Map<String, dynamic>>[
        legWire(
          mode: 'train',
          from: 'Praha hl.n.',
          to: 'Český Krumlov',
          depH: 9,
          depM: 0,
          arrH: 11,
          arrM: 0,
          line: 'R 999',
        ),
      ],
    );

/// Cesta zpět, 17:05–19:55. Samostatně vyhledaná — není to obrácená cesta tam.
Map<String, dynamic> homewardWire() => optionWire(
      id: 'home-1',
      transfers: 1,
      fare: kFare,
      legs: <Map<String, dynamic>>[
        legWire(
          mode: 'bus',
          from: 'Český Krumlov',
          to: 'České Budějovice',
          depH: 17,
          depM: 5,
          arrH: 17,
          arrM: 56,
          line: '340',
        ),
        legWire(
          mode: 'train',
          from: 'České Budějovice',
          to: 'Praha hl.n.',
          depH: 18,
          depM: 20,
          arrH: 19,
          arrM: 55,
          line: 'R 641',
          operatorName: 'České dráhy',
        ),
      ],
    );

/// Pozdější návrat, 19:40–20:42 — použije se jako „nejbližší možný".
Map<String, dynamic> lateHomewardWire() => optionWire(
      id: 'home-late',
      transfers: 0,
      legs: <Map<String, dynamic>>[
        legWire(
          mode: 'train',
          from: 'Český Krumlov',
          to: 'Praha hl.n.',
          depH: 19,
          depM: 40,
          arrH: 20,
          arrM: 42,
          line: 'R 645',
        ),
      ],
    );

/// Dřívější návrat, 15:30–17:40 — alternativa k ručnímu výběru.
Map<String, dynamic> earlyHomewardWire() => optionWire(
      id: 'home-early',
      transfers: 0,
      legs: <Map<String, dynamic>>[
        legWire(
          mode: 'train',
          from: 'Český Krumlov',
          to: 'Praha hl.n.',
          depH: 15,
          depM: 30,
          arrH: 17,
          arrM: 40,
          line: 'R 643',
        ),
      ],
    );

/// Pozdější cesta tam, příjezd 14:30.
Map<String, dynamic> lateOutboundWire() => optionWire(
      id: 'out-late',
      transfers: 0,
      legs: <Map<String, dynamic>>[
        legWire(
          mode: 'train',
          from: 'Praha hl.n.',
          to: 'Český Krumlov',
          depH: 12,
          depM: 30,
          arrH: 14,
          arrM: 30,
          line: 'R 642',
        ),
      ],
    );

Journey outboundJourney() => Journey.fromWire(outboundWire());
Journey homewardJourney() => Journey.fromWire(homewardWire());
Journey lateOutboundJourney() => Journey.fromWire(lateOutboundWire());
Journey lateHomewardJourney() => Journey.fromWire(lateHomewardWire());
Journey earlyHomewardJourney() => Journey.fromWire(earlyHomewardWire());

/// Výlet z Prahy do Českého Krumlova na 12. 9. 2026, den 7:00–21:00.
PlanContext testContext({DateTime? returnDate, DateTime? dayEndLocal}) =>
    PlanContext(
      tripId: 'trip-1',
      timezone: 'Europe/Prague',
      zoneOffset: kTestOffset,
      origin: const PlanPlace(
        name: 'Praha hl.n.',
        lat: 50.0830,
        lon: 14.4356,
      ),
      destination: const PlanPlace(
        name: 'Český Krumlov',
        lat: 48.8127,
        lon: 14.3175,
      ),
      planDate: DateTime(2026, 9, 12),
      returnDate: returnDate,
      dayStartLocal: wall(7, 0),
      dayEndLocal: dayEndLocal ?? wall(21, 0),
      groupSize: 4,
    );
