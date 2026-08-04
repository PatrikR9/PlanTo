import '../../app/env/env.dart';
import 'failure.dart';

/// The one place that decides what an error says on screen.
///
/// Three sessions in a row the expensive part of a bug was not the bug: it
/// was the app describing it wrongly. "Přihlaste se prosím znovu" is a
/// perfectly good sentence for a real user whose token expired, and a
/// complete dead end when the actual cause is a switch left off in the
/// Supabase dashboard. Retrying is exactly what will not work, and the
/// message says to retry.
///
/// So outside a production build the provider's own words come through.
/// "Anonymous sign-ins are disabled" is a dashboard toggle, not a bug, and
/// hiding it behind a friendly sentence costs hours — which is what
/// [Failure.debugMessage] was written for and what nothing was using.
///
/// Gated on the FLAVOUR rather than on kDebugMode on purpose: a release APK
/// built from env/dev.json is still a development build, and it is precisely
/// the build being carried around on a phone when this kind of thing bites.
String errorText(Object? error) {
  if (error is! Failure) return Failure.genericMessage;
  return Env.isProd ? error.userMessage : error.debugMessage;
}
