/// Nabídka bloků programu podle toho, co skupina zadala jako aktivity výletu.
///
/// Není to katalog míst a nemá jím být. Katalog `destinations` v databázi je,
/// ale zatím ho nic neplní — nabízet z něj znamená nabízet prázdno, nebo si
/// místa vymyslet. Vymyšlený hrad, který v okolí není, je přesně ta chyba,
/// kterou tenhle produkt dělat nesmí.
///
/// Tohle jsou naopak výhradně věci, které skupina sama řekla: štítky výletu.
/// Přidaná hodnota je jenom typická délka — „Turistika" bez délky se do dne
/// nedá zasadit a odhadovat ji pokaždé ručně je otrava.
library;

import 'package:flutter/foundation.dart';

import '../../trips/domain/activity_tag.dart';
import 'plan_item.dart';

@immutable
class ProgramSuggestion {
  const ProgramSuggestion({
    required this.label,
    required this.kind,
    required this.length,
    this.tag,
  });

  /// Null u obecných bloků, které nevycházejí ze štítku.
  final ActivityTag? tag;

  final String label;
  final PlanItemKind kind;
  final Duration length;
}

/// Co nabídnout skupině, která si zadala [tags].
///
/// Pořadí je pořadí štítků, ne abecedně: skupina je vybírala v nějakém
/// pořadí a to první je obvykle to hlavní. Na konci jsou dva obecné bloky,
/// které dávají smysl vždycky — i výlet bez jediného štítku se někde naobědvá
/// a někde si dá pauzu.
List<ProgramSuggestion> suggestionsFor(List<ActivityTag> tags) {
  final List<ProgramSuggestion> out = <ProgramSuggestion>[];
  final Set<ActivityTag> seen = <ActivityTag>{};

  for (final ActivityTag t in tags) {
    if (!seen.add(t)) continue;
    out.add(
      ProgramSuggestion(
        tag: t,
        label: t.label,
        kind: t.section == ActivitySection.food
            ? PlanItemKind.meal
            : PlanItemKind.activity,
        length: suggestedLength(t),
      ),
    );
  }

  out.addAll(kGenericSuggestions);
  return out;
}

/// Bloky, které nevycházejí z ničeho, co skupina zadala, a přesto sedí
/// pokaždé.
const List<ProgramSuggestion> kGenericSuggestions = <ProgramSuggestion>[
  ProgramSuggestion(
    label: 'Oběd',
    kind: PlanItemKind.meal,
    length: Duration(hours: 1),
  ),
  ProgramSuggestion(
    label: 'Volno',
    kind: PlanItemKind.free,
    length: Duration(hours: 1),
  ),
];

/// Jak dlouho takový bod obvykle trvá.
///
/// Je to výchozí hodnota k přetažení, ne tvrzení. Proto se nikde neukazuje
/// jako „potrvá to", vždycky jenom předvyplní délku, kterou jde hned změnit.
Duration suggestedLength(ActivityTag tag) =>
    _overrides[tag] ?? _bySection[tag.section]!;

/// Kde se typická délka výrazně liší od zbytku sekce. Zbytek si vystačí
/// s odhadem podle sekce — sedmdesát ručně nastavených čísel by nikdo
/// neudržoval a polovina by byla stejně vycucaná z prstu.
const Map<ActivityTag, Duration> _overrides = <ActivityTag, Duration>{
  ActivityTag.viewpoint: Duration(minutes: 45),
  ActivityTag.picnic: Duration(minutes: 90),
  ActivityTag.geocaching: Duration(minutes: 90),
  ActivityTag.stargazing: Duration(minutes: 90),
  ActivityTag.caves: Duration(minutes: 90),
  ActivityTag.ski: Duration(hours: 5),
  ActivityTag.snowboard: Duration(hours: 5),
  ActivityTag.christmasMarket: Duration(hours: 2),
  ActivityTag.skating: Duration(minutes: 90),
  ActivityTag.concert: Duration(hours: 3),
  ActivityTag.theatre: Duration(minutes: 150),
  ActivityTag.cinema: Duration(minutes: 150),
  ActivityTag.festival: Duration(hours: 4),
  ActivityTag.guidedTour: Duration(hours: 1),
  ActivityTag.cafe: Duration(minutes: 45),
  ActivityTag.restaurant: Duration(minutes: 75),
  ActivityTag.degustation: Duration(minutes: 90),
  ActivityTag.bbq: Duration(hours: 3),
  ActivityTag.wellness: Duration(hours: 3),
  ActivityTag.themePark: Duration(hours: 5),
  ActivityTag.zoo: Duration(hours: 3),
  ActivityTag.aquapark: Duration(hours: 3),
  ActivityTag.playground: Duration(hours: 1),
  ActivityTag.shopping: Duration(minutes: 90),
};

const Map<ActivitySection, Duration> _bySection = <ActivitySection, Duration>{
  ActivitySection.outdoor: Duration(hours: 3),
  ActivitySection.water: Duration(hours: 2),
  ActivitySection.winter: Duration(hours: 4),
  ActivitySection.culture: Duration(minutes: 90),
  ActivitySection.food: Duration(hours: 1),
  ActivitySection.relax: Duration(hours: 2),
};
