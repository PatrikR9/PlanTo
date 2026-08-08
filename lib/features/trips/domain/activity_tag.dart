import 'package:collection/collection.dart';

/// The groups the chips are drawn in.
///
/// Sections rather than one flat grid, because the list went from eight tags
/// to twenty-nine. A `Wrap` of twenty-nine chips is not a longer version of
/// a `Wrap` of eight — it is a wall, and the eye has nowhere to stop. With a
/// heading above each group you skip "Zima" in July in one glance.
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

  // --- u vody --------------------------------------------------------------
  // `lake` used to be labelled just "Voda" and carried everything wet. Splitting
  // the sea out of it is the whole reason this list grew: a pond in Třeboň and
  // the Adriatic differ in passport, sunburn, salt and eight hours of travel.
  lake('lake', 'Jezero a rybník', ActivitySection.water),
  sea('sea', 'Moře', ActivitySection.water),
  paddling('paddling', 'Vodáctví', ActivitySection.water),
  aquapark('aquapark', 'Aquapark', ActivitySection.water),

  // --- zima ----------------------------------------------------------------
  ski('ski', 'Lyže', ActivitySection.winter),
  crossCountry('cross_country', 'Běžky', ActivitySection.winter),
  skating('skating', 'Brusle', ActivitySection.winter),

  // --- město a kultura -----------------------------------------------------
  city('city', 'Město', ActivitySection.culture),
  castle('castle', 'Hrady a zámky', ActivitySection.culture),
  museum('museum', 'Muzea', ActivitySection.culture),
  gallery('gallery', 'Galerie', ActivitySection.culture),
  concert('concert', 'Koncert', ActivitySection.culture),
  theatre('theatre', 'Divadlo', ActivitySection.culture),
  festival('festival', 'Festivaly', ActivitySection.culture),
  market('market', 'Trhy', ActivitySection.culture),

  // --- jídlo a pití --------------------------------------------------------
  cafe('cafe', 'Kavárny', ActivitySection.food),
  restaurant('restaurant', 'Restaurace', ActivitySection.food),
  wine('wine', 'Vinařství', ActivitySection.food),
  brewery('brewery', 'Pivovary', ActivitySection.food),

  // --- odpočinek a rodina --------------------------------------------------
  wellness('wellness', 'Wellness a lázně', ActivitySection.relax),
  zoo('zoo', 'Zoo', ActivitySection.relax),
  themePark('theme_park', 'Zábavní park', ActivitySection.relax),
  shopping('shopping', 'Nákupy', ActivitySection.relax);

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
