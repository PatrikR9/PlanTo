import 'package:collection/collection.dart';

/// The groups the chips are drawn in.
///
/// Sections rather than one flat grid, because the list went from eight tags
/// to seventy-three. A `Wrap` of seventy-three chips is not a longer version
/// of a `Wrap` of eight — it is a wall, and the eye has nowhere to stop. With
/// a heading above each group you skip "Zima" in July in one glance.
///
/// Past about thirty the headings alone stopped being enough, which is why
/// the picker collapses each section and shows how many are chosen inside it.
enum ActivitySection {
  outdoor('Venku'),
  water('U vody'),
  winter('Zima'),
  culture('Město a kultura'),
  food('Jídlo a pití'),
  relax('Odpočinek a rodina');

  const ActivitySection(this.label);

  final String label;
}

/// What the group wants to do.
///
/// The client, the availability solver, the weather profile chooser and the
/// packing rules all agree on one vocabulary: [wire] is the exact string
/// stored in `trips.activity_tags` and matched by `packing_rules.activity_tags`.
///
/// [wire] is explicit rather than derived from the constant name. The first
/// eight values were serialised with `.name` and are already in the database,
/// so renaming a constant — or adding one whose Dart name is camelCase — must
/// not be able to change what an existing trip means.
enum ActivityTag {
  // --- venku ---------------------------------------------------------------
  hiking('hiking', 'Turistika', ActivitySection.outdoor),
  viewpoint('viewpoint', 'Vyhlídky', ActivitySection.outdoor),
  cycling('cycling', 'Kolo', ActivitySection.outdoor),
  climbing('climbing', 'Lezení', ActivitySection.outdoor),
  camping('camping', 'Kemp', ActivitySection.outdoor),
  caves('caves', 'Jeskyně', ActivitySection.outdoor),
  mtb('mtb', 'Horské kolo', ActivitySection.outdoor),
  viaFerrata('via_ferrata', 'Ferraty', ActivitySection.outdoor),
  running('running', 'Běh', ActivitySection.outdoor),
  geocaching('geocaching', 'Geocaching', ActivitySection.outdoor),
  mushrooming('mushrooming', 'Houbaření', ActivitySection.outdoor),
  fishing('fishing', 'Rybaření', ActivitySection.outdoor),
  horseRiding('horse_riding', 'Jízda na koni', ActivitySection.outdoor),
  stargazing('stargazing', 'Pozorování hvězd', ActivitySection.outdoor),
  picnic('picnic', 'Piknik', ActivitySection.outdoor),

  // --- u vody --------------------------------------------------------------
  // `lake` used to be labelled just "Voda" and carried everything wet. Splitting
  // the sea out of it is the whole reason this list grew: a pond in Třeboň and
  // the Adriatic differ in passport, sunburn, salt and eight hours of travel.
  lake('lake', 'Jezero a rybník', ActivitySection.water),
  sea('sea', 'Moře', ActivitySection.water),
  paddling('paddling', 'Vodáctví', ActivitySection.water),
  aquapark('aquapark', 'Aquapark', ActivitySection.water),
  swimming('swimming', 'Koupání', ActivitySection.water),
  snorkeling('snorkeling', 'Šnorchlování', ActivitySection.water),
  diving('diving', 'Potápění', ActivitySection.water),
  sailing('sailing', 'Jachting', ActivitySection.water),
  paddleboard('paddleboard', 'Paddleboard', ActivitySection.water),
  waterfall('waterfall', 'Vodopády', ActivitySection.water),

  // --- zima ----------------------------------------------------------------
  ski('ski', 'Lyže', ActivitySection.winter),
  crossCountry('cross_country', 'Běžky', ActivitySection.winter),
  skating('skating', 'Brusle', ActivitySection.winter),
  snowboard('snowboard', 'Snowboard', ActivitySection.winter),
  sledding('sledding', 'Sáňky a boby', ActivitySection.winter),
  snowshoes('snowshoes', 'Sněžnice', ActivitySection.winter),
  skiTouring('ski_touring', 'Skialp', ActivitySection.winter),
  winterHike('winter_hike', 'Zimní turistika', ActivitySection.winter),
  christmasMarket('christmas_market', 'Vánoční trhy', ActivitySection.winter),

  // --- město a kultura -----------------------------------------------------
  city('city', 'Město', ActivitySection.culture),
  castle('castle', 'Hrady a zámky', ActivitySection.culture),
  museum('museum', 'Muzea', ActivitySection.culture),
  gallery('gallery', 'Galerie', ActivitySection.culture),
  concert('concert', 'Koncert', ActivitySection.culture),
  theatre('theatre', 'Divadlo', ActivitySection.culture),
  festival('festival', 'Festivaly', ActivitySection.culture),
  market('market', 'Trhy', ActivitySection.culture),
  architecture('architecture', 'Architektura', ActivitySection.culture),
  cinema('cinema', 'Kino', ActivitySection.culture),
  technicalMonument(
    'technical_monument',
    'Technické památky',
    ActivitySection.culture,
  ),
  church('church', 'Kostely a kláštery', ActivitySection.culture),
  guidedTour('guided_tour', 'Prohlídka s průvodcem', ActivitySection.culture),
  streetArt('street_art', 'Street art', ActivitySection.culture),

  // --- jídlo a pití --------------------------------------------------------
  cafe('cafe', 'Kavárny', ActivitySection.food),
  restaurant('restaurant', 'Restaurace', ActivitySection.food),
  wine('wine', 'Vinařství', ActivitySection.food),
  brewery('brewery', 'Pivovary', ActivitySection.food),
  streetFood('street_food', 'Street food', ActivitySection.food),
  farmersMarket('farmers_market', 'Farmářské trhy', ActivitySection.food),
  distillery('distillery', 'Palírny', ActivitySection.food),
  degustation('degustation', 'Degustace', ActivitySection.food),
  bbq('bbq', 'Grilování', ActivitySection.food),

  // --- odpočinek a rodina --------------------------------------------------
  wellness('wellness', 'Wellness a lázně', ActivitySection.relax),
  zoo('zoo', 'Zoo', ActivitySection.relax),
  themePark('theme_park', 'Zábavní park', ActivitySection.relax),
  shopping('shopping', 'Nákupy', ActivitySection.relax),
  spaPool('spa_pool', 'Termály', ActivitySection.relax),
  playground('playground', 'Hřiště', ActivitySection.relax),
  farm('farm', 'Farma a statek', ActivitySection.relax),
  botanical('botanical', 'Botanická zahrada', ActivitySection.relax),
  planetarium('planetarium', 'Planetárium', ActivitySection.relax),
  escapeRoom('escape_room', 'Únikovka', ActivitySection.relax),
  bowling('bowling', 'Bowling', ActivitySection.relax),
  boardGames('board_games', 'Deskovky', ActivitySection.relax);

  const ActivityTag(this.wire, this.label, this.section);

  /// The value stored in the database. Never derived from the constant name.
  final String wire;
  final String label;
  final ActivitySection section;

  static ActivityTag? fromWire(String? v) =>
      ActivityTag.values.firstWhereOrNull((ActivityTag t) => t.wire == v);

  static List<ActivityTag> inSection(ActivitySection s) =>
      ActivityTag.values.where((ActivityTag t) => t.section == s).toList();
}
