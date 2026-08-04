/// A stopgap list of places people actually go.
///
/// The real thing is the `destinations` table: curated, scored, with entrance
/// fees and activity tags. It is empty because filling it properly is its own
/// milestone, and because of a licence trap worth restating here — extracting
/// a curated table from OpenStreetMap makes it an ODbL *Derivative Database*
/// with share-alike obligations. Coordinates come from Wikidata (CC0)
/// instead. That is the most-missed trap in travel apps (cost register C1).
///
/// Twenty entries typed by hand are not a derivative of anything. They exist
/// so the transport estimate has somewhere to measure to, and they go away
/// the day the table is seeded.
class TripDestination {
  const TripDestination(this.name, this.lat, this.lon, this.region);

  final String name;
  final double lat;
  final double lon;

  /// Shown under the name, because "Bezděz" means nothing to somebody from
  /// Ostrava and "Máchův kraj" does.
  final String region;
}

const List<TripDestination> kDestinations = <TripDestination>[
  TripDestination('Český Krumlov', 48.8127, 14.3175, 'Jižní Čechy'),
  TripDestination('Karlštejn', 49.9394, 14.1881, 'Střední Čechy'),
  TripDestination('Kutná Hora', 49.9484, 15.2681, 'Střední Čechy'),
  TripDestination('Adršpach', 50.6167, 16.1167, 'Královéhradecký kraj'),
  TripDestination('Pravčická brána', 50.8828, 14.2758, 'České Švýcarsko'),
  TripDestination('Špindlerův Mlýn', 50.7256, 15.6094, 'Krkonoše'),
  TripDestination('Pec pod Sněžkou', 50.6931, 15.7314, 'Krkonoše'),
  TripDestination('Macocha', 49.3728, 16.7269, 'Moravský kras'),
  TripDestination('Lednice', 48.8014, 16.8053, 'Jižní Morava'),
  TripDestination('Mikulov', 48.8058, 16.6375, 'Jižní Morava'),
  TripDestination('Telč', 49.1841, 15.4528, 'Vysočina'),
  TripDestination('Třeboň', 49.0031, 14.7706, 'Jižní Čechy'),
  TripDestination('Lipno nad Vltavou', 48.6403, 14.2231, 'Šumava'),
  TripDestination('Železná Ruda', 49.1381, 13.2350, 'Šumava'),
  TripDestination('Jeseníky – Praděd', 50.0833, 17.2306, 'Jeseníky'),
  TripDestination('Beskydy – Pustevny', 49.4906, 18.2775, 'Beskydy'),
  TripDestination('Bezděz', 50.5386, 14.7203, 'Máchův kraj'),
  TripDestination('Sněžka', 50.7361, 15.7397, 'Krkonoše'),
  TripDestination('Olomouc', 49.5938, 17.2509, 'Střední Morava'),
  TripDestination('Vídeň', 48.2082, 16.3738, 'Rakousko'),
  TripDestination('Drážďany', 51.0504, 13.7373, 'Sasko'),
  TripDestination('Bratislava', 48.1486, 17.1077, 'Slovensko'),
];
