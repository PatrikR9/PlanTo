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

/// Runs [body], mapping anything it throws into a [Failure].
Future<T> guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (error, stackTrace) {
    throw mapError(error, stackTrace);
  }
}
