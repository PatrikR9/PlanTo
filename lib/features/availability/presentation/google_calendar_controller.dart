import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/env/env.dart';
import '../../dates/data/date_repository.dart';
import '../../trips/presentation/controllers/trips_controller.dart';
import '../data/availability_repository.dart';
import '../data/google_calendar_repository.dart';
import '../domain/google_calendar.dart';

/// Připojení kalendáře Googlem — cesta pro prohlížeč.
///
/// Na Androidu je rychlejší cesta pořád `planto_calendar`: jedno systémové
/// oprávnění, žádná síť, žádný cizí účet. Tohle existuje kvůli pozvanému,
/// který přišel z odkazu ve skupinovém chatu a skončil v prohlížeči, kde
/// žádné API ke kalendáři není.
class GoogleCalendarController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  /// Otevře obrazovku souhlasu. Odtud se aplikace vrací přes docs/oauth.html
  /// na routu `/calendar-callback`, kde pokračuje [finish].
  Future<bool> connect(String tripId) async {
    if (!Env.googleCalendarEnabled) return false;

    final Uri url = googleConsentUrl(
      clientId: Env.googleCalendarClientId,
      redirectUri: Env.oauthRedirectUri,
      tripId: tripId,
      isWeb: kIsWeb,
    );

    return launchUrl(
      url,
      // Na webu ve stejné záložce: nová by znamenala, že se uživatel vrátí do
      // aplikace, která o ničem neví, zatímco původní záložka pořád čeká.
      // Na Androidu externě, aby souhlas běžel v prohlížeči s uloženým
      // přihlášením ke Googlu, ne ve WebView bez něj.
      webOnlyWindowName: '_self',
      mode:
          kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
    );
  }

  /// Dokončí připojení kódem, který se vrátil z Googlu, a rovnou načte
  /// obsazenost. Jedno volání funkce, protože pro uživatele je to jeden krok.
  Future<bool> finish({required String tripId, required String code}) =>
      _run(tripId, (GoogleCalendarRepository r) => r.sync(tripId, code: code));

  /// Opakované načtení bez další obrazovky souhlasu — od toho je uložený
  /// refresh token.
  Future<bool> resync(String tripId) =>
      _run(tripId, (GoogleCalendarRepository r) => r.sync(tripId));

  Future<bool> disconnect(String tripId) =>
      _run(tripId, (GoogleCalendarRepository r) => r.disconnect());

  Future<bool> _run(
    String tripId,
    Future<void> Function(GoogleCalendarRepository r) body,
  ) async {
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(() async {
      await body(ref.read(googleCalendarRepositoryProvider));
      ref
        ..invalidate(googleAccountProvider)
        ..invalidate(myBlocksProvider(tripId))
        ..invalidate(availabilityProvider(tripId))
        ..invalidate(dateCandidatesProvider(tripId))
        ..invalidate(tripProvider(tripId))
        ..invalidate(myTripsProvider);
    });
    return !state.hasError;
  }
}

final AsyncNotifierProvider<GoogleCalendarController, void>
    googleCalendarControllerProvider =
    AsyncNotifierProvider<GoogleCalendarController, void>(
  GoogleCalendarController.new,
);
