import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'failure.dart';

/// Maps infrastructure exceptions to domain failures.
///
/// Call this in repository implementations only. Nothing above the data layer
/// should ever see a PostgrestException or a SocketException.
Failure mapError(Object error, [StackTrace? stackTrace]) {
  return switch (error) {
    Failure() => error,
    SocketException() ||
    TimeoutException() =>
      NetworkFailure(cause: error, stackTrace: stackTrace),
    // Supabase reports a taken address as a generic 422; without this the
    // user just sees "sign in again" and loops forever.
    AuthApiException(code: 'over_email_send_rate_limit') ||
    AuthApiException(code: 'over_request_rate_limit') =>
      EmailRateLimitFailure(cause: error),
    AuthApiException(code: 'email_exists') =>
      EmailAlreadyRegisteredFailure(email: '', cause: error),
    AuthException() => AuthFailure(cause: error, stackTrace: stackTrace),
    // An Edge Function that answers 4xx THROWS — it does not come back as a
    // response with an error field, which is what the repositories were
    // checking for. So every "your calendar link is a 404" arrived at the
    // user as "Něco se pokazilo", and the one useful sentence was thrown
    // away at the boundary.
    FunctionException(:final dynamic details) =>
      ValidationFailure(message: _functionMessage(details), cause: error),
    PostgrestException(:final String? code) => switch (code) {
        // Postgres insufficient_privilege — almost always an RLS policy
        // rejection, which from the user's side means "not signed in properly".
        '42501' => AuthFailure(cause: error, stackTrace: stackTrace),
        '23505' =>
          const ValidationFailure(message: 'Tento záznam už existuje.'),
        _ => ServerFailure(code: code, cause: error, stackTrace: stackTrace),
      },
    _ => ServerFailure(cause: error, stackTrace: stackTrace),
  };
}

/// Digs the function's own message out of its body.
///
/// Supabase parses the JSON for us, so `details` is usually the decoded map.
/// Falling back to the generic sentence is right when it is not: a raw stack
/// trace from Deno is not something to show a person.
String _functionMessage(Object? details) {
  if (details is Map && details['error'] != null) {
    return details['error'].toString();
  }
  if (details is String && details.isNotEmpty && details.length < 200) {
    return details;
  }
  return Failure.genericMessage;
}

/// Runs [body], mapping anything it throws into a [Failure].
Future<T> guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (error, stackTrace) {
    throw mapError(error, stackTrace);
  }
}
