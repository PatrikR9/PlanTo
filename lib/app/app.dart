import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/design_system/components/components.dart';
import 'env/env.dart';
import 'router/router.dart';

class PlanToApp extends ConsumerWidget {
  const PlanToApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GoRouter router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: Env.appName,
      // The corner ribbon adds nothing — the app bar title already says
      // "PlanTo (dev)" and the flavour is visible in the window title.
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,

      // Czech is the default and the source locale. The Settings screen (M11)
      // overrides this independently of the OS locale, so a Czech user with an
      // English phone still gets Czech.
      locale: const Locale('cs'),
      supportedLocales: const <Locale>[Locale('cs'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      builder: (BuildContext context, Widget? child) {
        final MediaQueryData mq = MediaQuery.of(context);
        return MediaQuery(
          // Cap text scaling so a 200% accessibility setting cannot break the
          // layout outright. The layouts themselves are still tested at 200%.
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(maxScaleFactor: 2.0),
          ),
          child: _LocalOnlyBanner(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}

/// Impossible-to-miss reminder that no backend is attached.
///
/// Worth the few lines: silently showing empty screens because Supabase is
/// unconfigured wastes far more time than a stripe at the bottom.
class _LocalOnlyBanner extends StatelessWidget {
  const _LocalOnlyBanner({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Env.isConfigured) return child;

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: <Widget>[
          Expanded(child: child),
          SafeArea(
            top: false,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.errorContainer,
              child: SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: Sp.xs,
                    horizontal: Sp.md,
                  ),
                  child: Text(
                    // The old wording — "env/dev.json chybí" — named the
                    // wrong thing. The file is usually right there; what is
                    // missing is the FLAG that reads it. SUPABASE_URL and
                    // SUPABASE_ANON_KEY arrive through String.fromEnvironment,
                    // which is resolved at COMPILE time, so an APK built
                    // without --dart-define-from-file has empty strings baked
                    // into it for good. Reinstalling cannot fix it; only
                    // rebuilding can, and the message has to say which.
                    kReleaseMode
                        ? 'Bez backendu — APK sestavené bez '
                            '--dart-define-from-file'
                        : 'Bez backendu — spusťte s '
                            '--dart-define-from-file=env/dev.json',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
