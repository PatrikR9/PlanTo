import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planto/core/design_system/components/components.dart';

void main() {
  Widget wrap(Widget child, {Brightness brightness = Brightness.light}) {
    return MaterialApp(
      theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      home: Scaffold(body: Center(child: child)),
    );
  }

  group('PtScoreRing', () {
    testWidgets('renders the score and an accessible label', (tester) async {
      await tester.pumpWidget(
        wrap(const PtScoreRing(score: 84, semanticLabel: 'Počasí 84 ze 100, dobré')),
      );
      await tester.pumpAndSettle();

      expect(find.text('84'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Počasí 84 ze 100, dobré'),
        findsOneWidget,
        reason: 'the ring must be readable without sight of the colour',
      );
    });

    testWidgets('rejects out-of-range scores', (tester) async {
      expect(
        () => PtScoreRing(score: 101, semanticLabel: 'x'),
        throwsAssertionError,
      );
    });
  });

  group('PtButton', () {
    testWidgets('does not fire while loading', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        wrap(PtButton(label: 'Uložit', isLoading: true, onPressed: () => taps++)),
      );
      await tester.tap(find.byType(FilledButton));
      expect(taps, 0);
    });
  });

  group('theme', () {
    test('both themes expose the PlanTo extension', () {
      expect(AppTheme.light().extension<PlanToTheme>(), isNotNull);
      expect(AppTheme.dark().extension<PlanToTheme>(), isNotNull);
    });
  });
}
