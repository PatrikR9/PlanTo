/// Nabídka bloků programu.
///
/// Testuje se to, co se dá pokazit tiše: že nabídka nevymýšlí místa, že jde
/// jenom o štítky, které skupina sama zadala, a že jídlo je jídlo — na tom
/// stojí ikona i to, co se pak objeví v seznamu.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/planner/domain/plan_item.dart';
import 'package:planto/features/planner/domain/program_suggestion.dart';
import 'package:planto/features/trips/domain/activity_tag.dart';

void main() {
  group('nabídka programu', () {
    test('výlet bez štítků dostane jen obecné bloky', () {
      final List<ProgramSuggestion> out = suggestionsFor(const <ActivityTag>[]);

      expect(out.length, kGenericSuggestions.length);
      expect(
        out.every((ProgramSuggestion s) => s.tag == null),
        isTrue,
        reason: 'nic se nesmí vzít odjinud než ze štítků výletu',
      );
    });

    test('nabídka vychází ze štítků a drží jejich pořadí', () {
      final List<ProgramSuggestion> out = suggestionsFor(<ActivityTag>[
        ActivityTag.hiking,
        ActivityTag.castle,
      ]);

      expect(out.first.tag, ActivityTag.hiking);
      expect(out.first.label, 'Turistika');
      expect(out[1].tag, ActivityTag.castle);
    });

    test('stejný štítek dvakrát nabídku nezdvojí', () {
      final List<ProgramSuggestion> out = suggestionsFor(<ActivityTag>[
        ActivityTag.hiking,
        ActivityTag.hiking,
      ]);

      expect(
        out.where((ProgramSuggestion s) => s.tag == ActivityTag.hiking).length,
        1,
      );
    });

    test('jídlo a pití je jídlo, zbytek je program', () {
      final List<ProgramSuggestion> out = suggestionsFor(<ActivityTag>[
        ActivityTag.restaurant,
        ActivityTag.museum,
      ]);

      expect(out.first.kind, PlanItemKind.meal);
      expect(out[1].kind, PlanItemKind.activity);
    });

    test('každý štítek má nenulovou délku', () {
      for (final ActivityTag t in ActivityTag.values) {
        expect(
          suggestedLength(t) > Duration.zero,
          isTrue,
          reason: 'bez délky se blok nedá zasadit do dne (${t.wire})',
        );
      }
    });

    test('délka se liší podle toho, o co jde', () {
      expect(
        suggestedLength(ActivityTag.viewpoint) <
            suggestedLength(ActivityTag.hiking),
        isTrue,
        reason: 'vyhlídka není celodenní túra',
      );
      expect(
        suggestedLength(ActivityTag.cafe) <
            suggestedLength(ActivityTag.themePark),
        isTrue,
      );
    });
  });
}
