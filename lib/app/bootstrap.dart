import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/storage/secure_supabase_storage.dart';
import 'app.dart';
import 'env/env.dart';

/// Single entry point for all flavours.
///
/// Everything that must happen before the first frame happens here, and
/// nothing else does — the cold-start budget is 1.5 s on a mid-range Android
/// device (architecture section 7.7).
///
/// NOTE ON ZONES: `WidgetsFlutterBinding.ensureInitialized()` and `runApp()`
/// must run in the SAME zone. Initialising the binding outside
/// `runZonedGuarded` and calling runApp inside it throws "Zone mismatch" and
/// leaves the app on a blank screen. Everything therefore lives inside the
/// zone, with `Env` (which needs no binding) as the only thing outside it.
Future<void> bootstrap() async {
  Env.assertConfigured();

  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Czech date and number symbols. Without this DateFormat('d. M.', 'cs')
      // throws at runtime the first time a trip card is built.
      Intl.defaultLocale = 'cs';
      await initializeDateFormatting('cs');

      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        // M10: forward to Crashlytics here.
      };

      if (Env.isConfigured) {
        await Supabase.initialize(
          url: Env.supabaseUrl,
          // Renamed from `anonKey` in supabase_flutter 2.16. It still accepts
          // a legacy anon JWT, which is what env/dev.json holds.
          publishableKey: Env.supabaseAnonKey,
          debug: !Env.isProd,
          authOptions: const FlutterAuthClientOptions(
            // Keeps the refresh token out of plain SharedPreferences.
            localStorage: SecureSupabaseStorage(),
          ),
        );
      } else if (kDebugMode) {
        debugPrint(
          'PlanTo: running WITHOUT a backend. UI only. '
          'Pass --dart-define-from-file=env/dev.json',
        );
      }

      runApp(const ProviderScope(child: PlanToApp()));
    },
    (Object error, StackTrace stack) {
      if (kDebugMode) debugPrint('Uncaught: $error\n$stack');
      // M10: Crashlytics.recordError(error, stack, fatal: true);
    },
  );
}
