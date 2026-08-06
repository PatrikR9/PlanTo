import 'package:flutter/foundation.dart';

/// Where an item belongs in the list.
///
/// Five groups, not fifteen. A packing list is scanned, not read, and the
/// point of grouping is that your eye can skip a whole block once you have
/// dealt with it.
enum PackingCategory {
  clothing('clothing', 'Oblečení'),
  gear('gear', 'Vybavení'),
  documents('documents', 'Doklady a peníze'),
  food('food', 'Jídlo a pití'),
  safety('safety', 'Bezpečnost');

  const PackingCategory(this.wire, this.label);

  final String wire;
  final String label;

  static PackingCategory? fromWire(String? v) => switch (v) {
        'clothing' => PackingCategory.clothing,
        'gear' => PackingCategory.gear,
        'documents' => PackingCategory.documents,
        'food' => PackingCategory.food,
        'safety' => PackingCategory.safety,
        _ => null,
      };
}

/// One thing to put in the bag.
///
/// [reasonKey] is the whole reason this list is trustworthy. An item with no
/// stated cause is indistinguishable from an item the app always suggests, so
/// people either carry everything forever or stop reading. "Prší v sobotu
/// odpoledne" is what makes a raincoat worth the space this once.
@immutable
class PackingItem {
  const PackingItem({
    required this.itemKey,
    required this.category,
    required this.priority,
    required this.reasonKey,
    required this.checked,
    required this.weatherBased,
  });

  final String itemKey;
  final PackingCategory category;

  /// 1 = don't leave without it, 2 = recommended, 3 = if it fits.
  final int priority;

  final String reasonKey;
  final bool checked;

  /// True when the item is on the list because of the forecast, so the screen
  /// can warn that it will change if the date moves. Without this, a list that
  /// silently loses four items after a re-vote looks like a bug.
  final bool weatherBased;

  bool get isEssential => priority == 1;

  String get label => _labels[itemKey] ?? itemKey;
  String get reason => _reasons[reasonKey] ?? '';

  PackingItem copyWith({bool? checked}) => PackingItem(
        itemKey: itemKey,
        category: category,
        priority: priority,
        reasonKey: reasonKey,
        checked: checked ?? this.checked,
        weatherBased: weatherBased,
      );

  static PackingItem? fromRow(Map<String, dynamic> r) {
    final PackingCategory? c = PackingCategory.fromWire(r['category'] as String?);
    final String? key = r['item_key'] as String?;
    // A rule this build has never heard of is dropped rather than shown as a
    // raw key. Seeding a new rule then stays a server-only change.
    if (c == null || key == null || !_labels.containsKey(key)) return null;
    return PackingItem(
      itemKey: key,
      category: c,
      priority: (r['priority'] as num?)?.toInt() ?? 2,
      reasonKey: r['reason_key'] as String? ?? '',
      checked: (r['checked'] as bool?) ?? false,
      weatherBased: (r['weather_based'] as bool?) ?? false,
    );
  }
}

/// The database stores keys; the sentences live here.
///
/// Not in the ARB file yet, and deliberately: these are 45 strings that will
/// churn while the rules are being tuned, and moving them into l10n before
/// English exists would double the editing without buying anything. They move
/// the day the second locale does.
const Map<String, String> _labels = <String, String>{
  'pack.id': 'Občanka nebo pas',
  'pack.phone_charger': 'Nabíječka na telefon',
  'pack.water': 'Voda',
  'pack.cash': 'Hotovost',
  'pack.snack': 'Něco k jídlu na cestu',
  'pack.powerbank': 'Powerbanka',
  'pack.rain_jacket': 'Pláštěnka nebo nepromokavá bunda',
  'pack.umbrella': 'Deštník',
  'pack.rain_trousers': 'Nepromokavé kalhoty',
  'pack.dry_bag': 'Nepromokavý obal na věci',
  'pack.warm_layer': 'Mikina nebo teplá vrstva',
  'pack.hat_gloves': 'Čepice a rukavice',
  'pack.thermos': 'Termoska',
  'pack.winter_boots': 'Zimní boty',
  'pack.sunscreen': 'Opalovací krém',
  'pack.sunglasses': 'Sluneční brýle',
  'pack.sun_hat': 'Pokrývka hlavy',
  'pack.extra_water': 'Víc vody, než si myslíš',
  'pack.windbreaker': 'Větrovka',
  'pack.headtorch': 'Čelovka',
  'pack.hiking_boots': 'Turistické boty',
  'pack.blister_plasters': 'Náplasti na puchýře',
  'pack.offline_map': 'Offline mapa',
  'pack.first_aid': 'Malá lékárnička',
  'pack.poles': 'Trekové hole',
  'pack.tick_repellent': 'Repelent na klíšťata',
  'pack.swimwear': 'Plavky',
  'pack.towel': 'Ručník',
  'pack.flip_flops': 'Žabky',
  'pack.comfy_shoes': 'Pohodlné boty',
  'pack.light_layer': 'Tenká mikina',
  'pack.earplugs': 'Špunty do uší',
  'pack.poncho': 'Pláštěnka',
  'pack.driving_licence': 'Řidičák',
  'pack.vignette': 'Dálniční známka',
  'pack.phone_holder': 'Držák na telefon',
  'pack.ticket_app': 'Jízdenka nebo appka dopravce',
  'pack.headphones': 'Sluchátka',
  'pack.toothbrush': 'Kartáček a pasta',
  'pack.change_clothes': 'Oblečení na převlečení',
  'pack.dry_socks': 'Suché ponožky navíc',
  'pack.deodorant': 'Deodorant',
  'pack.medication': 'Léky, které bereš',
  'pack.laundry_bag': 'Sáček na špinavé prádlo',

  // --- moře ---
  'pack.passport': 'Pas nebo občanka na cesty',
  'pack.ehic': 'Evropský průkaz pojištěnce',
  'pack.beach_towel': 'Osuška na pláž',
  'pack.water_shoes': 'Boty do vody',
  'pack.after_sun': 'Krém po opalování',
  'pack.sunscreen_high': 'Opalovací krém s vysokým faktorem',
  'pack.snorkel': 'Šnorchl a brýle',

  // --- vodáctví a aquapark ---
  'pack.quick_dry': 'Rychleschnoucí oblečení',
  'pack.swim_cap': 'Koupací čepice',

  // --- zima ---
  'pack.ski_pass': 'Skipas nebo rezervace',
  'pack.goggles': 'Lyžařské brýle',
  'pack.helmet': 'Helma',
  'pack.thermal_layer': 'Termoprádlo',
  'pack.ski_gloves': 'Lyžařské rukavice',

  // --- kolo ---
  'pack.bike_helmet': 'Helma na kolo',
  'pack.repair_kit': 'Lepení a pumpička',
  'pack.bike_lights': 'Světla na kolo',
  'pack.bike_lock': 'Zámek na kolo',

  // --- lezení ---
  'pack.climb_harness': 'Sedák a jistítko',
  'pack.climb_shoes': 'Lezečky',
  'pack.chalk': 'Magnézium',

  // --- kemp ---
  'pack.sleeping_bag': 'Spacák',
  'pack.sleeping_pad': 'Karimatka',
  'pack.mosquito': 'Repelent na komáry',

  // --- kultura ---
  'pack.tickets': 'Vstupenky',
  'pack.smart_clothes': 'Něco společenského na sebe',

  // --- gastro ---
  'pack.designated_driver': 'Domluvit, kdo řídí',
  'pack.cooler_bag': 'Chladicí taška',

  // --- wellness ---
  'pack.bathrobe': 'Župan',

  // --- ostatní ---
  'pack.tote_bag': 'Látková taška',
};

/// Why each item is on the list. Phrased as a cause, never as an instruction —
/// "prší odpoledne" tells you something you can weigh; "vezmi si pláštěnku"
/// just repeats the item above it in different words.
const Map<String, String> _reasons = <String, String>{
  'reason.always': 'ať jedete kamkoli',
  'reason.cash_outside_city': 'mimo město kartou nezaplatíte všude',
  'reason.navigation_drains_battery': 'navigace sežere baterku rychleji, než čekáš',
  'reason.rain_expected': 'na termín je hlášený déšť',
  'reason.heavy_rain': 'hlášený je vydatný déšť, ne přeháňka',
  'reason.cold_day': 'bude chladno',
  'reason.freezing': 'teploty kolem nuly',
  'reason.snow': 'hlášené sněžení',
  'reason.strong_sun': 'silné UV',
  'reason.hot_day': 'bude horko',
  'reason.windy': 'hlášené silné nárazy větru',
  'reason.back_after_sunset': 'vracíte se po setmění',
  'reason.activity_hiking': 'jdete na turistiku',
  'reason.no_signal_in_hills': 'v kopcích nemusí být signál',
  'reason.tick_season': 'sezóna klíšťat',
  'reason.activity_lake': 'jedete k vodě',
  'reason.activity_city': 'chození po městě',
  'reason.cold_interiors': 'v interiérech bývá chladno i v létě',
  'reason.activity_festival': 'jedete na festival',
  'reason.going_by_car': 'jedete autem',
  'reason.motorway_vignette': 'po dálnici bez známky ne',
  'reason.going_by_public': 'jedete veřejnou dopravou',
  'reason.overnight': 'jedete přes noc',
  'reason.overnight_hiking': 'turistika přes noc',
  'reason.longer_trip': 'delší výlet',

  'reason.going_abroad': 'jedete přes hranice',
  'reason.activity_sea': 'jedete k moři',
  'reason.rocky_beaches': 'oblázkové pláže a ježovky',
  'reason.sea_sun_is_stronger': 'u moře slunce pálí víc',
  'reason.activity_paddling': 'jedete na vodu',
  'reason.activity_aquapark': 'jdete do aquaparku',
  'reason.activity_ski': 'jedete lyžovat',
  'reason.activity_winter': 'zimní sporty',
  'reason.snow_reflects_uv': 'sníh odráží UV víc než písek',
  'reason.activity_cycling': 'jedete na kole',
  'reason.activity_climbing': 'jdete lézt',
  'reason.activity_camping': 'spíte v kempu',
  'reason.camping_summer': 'letní večery u vody',
  'reason.caves_are_cold': 'v jeskyni je osm stupňů celý rok',
  'reason.caves_are_wet': 'v jeskyni je mokro a kluzko',
  'reason.booked_seat': 'máte rezervované místo',
  'reason.activity_concert': 'jdete na koncert',
  'reason.activity_theatre': 'jdete do divadla',
  'reason.markets_want_cash': 'na trzích se platí hotově',
  'reason.tasting_and_driving': 'degustace a řízení nejde dohromady',
  'reason.activity_wine': 'vezete si něco domů',
  'reason.activity_wellness': 'jdete do wellness',
  'reason.long_day_on_feet': 'celý den na nohou',
  'reason.overpriced_inside': 'uvnitř je jídlo dvakrát dražší',
  'reason.activity_shopping': 'jdete nakupovat',
};
