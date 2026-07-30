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
    expect(
      find.text('Bez backendu — env/dev.json chybí'),
      findsOneWidget,
      reason: 'the local-only banner must be impossible to miss',
    );
  });
}
