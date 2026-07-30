/// Origin cities, hard-coded.
///
/// M2 needs coordinates for the trip origin and has no geocoder. Rather than
/// take a dependency on Nominatim — whose usage policy forbids exactly this
/// kind of interactive lookup (cost register, section C1) — the twenty cities
/// that cover the launch market are simply listed here. It is free, instant,
/// works offline, and is honestly enough: nobody plans a group trip from a
/// village of 400 people without also naming a station.
///
/// A real geocoder arrives in M7 alongside MOTIS, which has one built in.
class OriginCity {
  const OriginCity(this.name, this.lat, this.lon);
  final String name;
  final double lat;
  final double lon;
}

const List<OriginCity> kOriginCities = <OriginCity>[
  OriginCity('Praha', 50.0755, 14.4378),
  OriginCity('Brno', 49.1951, 16.6068),
  OriginCity('Ostrava', 49.8209, 18.2625),
  OriginCity('Plzeň', 49.7384, 13.3736),
  OriginCity('Liberec', 50.7663, 15.0543),
  OriginCity('Olomouc', 49.5938, 17.2509),
  OriginCity('České Budějovice', 48.9745, 14.4743),
  OriginCity('Hradec Králové', 50.2092, 15.8328),
  OriginCity('Ústí nad Labem', 50.6607, 14.0323),
  OriginCity('Pardubice', 50.0343, 15.7812),
  OriginCity('Zlín', 49.2265, 17.6683),
  OriginCity('Havířov', 49.7798, 18.4368),
  OriginCity('Kladno', 50.1477, 14.1028),
  OriginCity('Most', 50.5031, 13.6362),
  OriginCity('Opava', 49.9387, 17.9026),
  OriginCity('Jihlava', 49.3961, 15.5912),
  OriginCity('Karlovy Vary', 50.2306, 12.8712),
  OriginCity('Bratislava', 48.1486, 17.1077),
  OriginCity('Košice', 48.7164, 21.2611),
  OriginCity('Žilina', 49.2231, 18.7394),
];
