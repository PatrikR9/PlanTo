import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planto/app/app.dart';

void main() {
  testWidgets('app boots into the trips shell without a backend',
      (WidgetTester tester) async {
    // No --dart-define in tests, so Env.isConfigured is false and the app
    // runs in local-only mode. That this path works is itself worth asserting:
    // it is what keeps UI work unblocked when Supabase is down or unset.
    await tester.pumpWidget(const ProviderScope(child: PlanToApp()));
    await tester.pumpAndSettle();

    expect(find.text('Výlety'), findsWidgets);
    expect(find.text('Zatím žádné výlety'), findsOneWidget);

    // By key, not by sentence. This assertion used to name the exact wording,
    // which then changed for a good reason — the old copy blamed a missing
    // env/dev.json when the file was present and the --dart-define flag was
    // not — and the test kept failing for the one thing it did not care
    // about. What it cares about is that the stripe exists at all.
    expect(
      find.byKey(const Key('local-only-banner')),
      findsOneWidget,
      reason: 'the local-only banner must be impossible to miss',
    );
    // And that it still names the condition rather than just being coloured.
    expect(find.textContaining('Bez backendu'), findsOneWidget);
  });
}
