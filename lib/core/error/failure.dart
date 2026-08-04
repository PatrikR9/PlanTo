/// Sealed failure hierarchy (architecture section 15.4).
///
/// Data-layer exceptions are mapped here exactly once, at the repository
/// boundary. The UI switches on the sealed type — there is no `catch (e)` in
/// a widget anywhere in this codebase, and no raw exception text ever reaches
/// a user.
sealed class Failure implements Exception {
  const Failure({this.cause, this.stackTrace});

  final Object? cause;
  final StackTrace? stackTrace;

  static const String genericMessage =
      'Něco se pokazilo. Zkuste to prosím znovu.';

  /// The provider's own words. Useless to a user, essential to a developer —
  /// "Anonymous sign-ins are disabled" is a dashboard toggle, not a bug, and
  /// hiding it behind a friendly sentence costs hours.
  String get debugMessage {
    final Object? c = cause;
    if (c == null) return userMessage;
    return '$userMessage\n\n[$runtimeType] $c';
  }

  /// Czech is the source locale. These are placeholders until M1 wires
  /// gen-l10n through; at that point this getter takes a BuildContext or the
  /// mapping moves into the presentation layer.
  String get userMessage => switch (this) {
        NetworkFailure() => 'Nejste připojeni k internetu.',
        AuthFailure() => 'Přihlaste se prosím znovu.',
        EmailAlreadyRegisteredFailure() => 'Na tento e-mail už účet existuje.',
        EmailRateLimitFailure() => 'Odesílání e-mailů je dočasně vyčerpané. '
            'Zkuste to za hodinu, nebo pokračujte jako host.',
        PermissionFailure() => 'Aplikace nemá potřebné oprávnění.',
        QuotaFailure() => 'Vyčerpali jste měsíční limit.',
        EntitlementFailure() => 'Tato funkce je součástí PlanTo Pro.',
        ValidationFailure(:final String message) => message,
        ServerFailure() => genericMessage,
      };

  /// Whether a retry button makes sense.
  bool get isRetryable => switch (this) {
        NetworkFailure() || ServerFailure() => true,
        _ => false,
      };
}

final class NetworkFailure extends Failure {
  const NetworkFailure({super.cause, super.stackTrace});
}

final class AuthFailure extends Failure {
  const AuthFailure({super.cause, super.stackTrace});
}

/// The mail provider refused to send — almost always the rate limit.
///
/// Supabase's built-in mailer allows 2 messages per hour for the WHOLE
/// project, so during development this fires constantly. Telling the user to
/// "sign in again" would be actively misleading: retrying is exactly what
/// will not work.
final class EmailRateLimitFailure extends Failure {
  const EmailRateLimitFailure({super.cause});
}

/// A guest tried to attach an address that already belongs to another account.
///
/// This is not an error the user did anything wrong to cause, and it has no
/// silent fix: Supabase cannot merge two identities, so the only honest
/// options are "sign in to the existing account and lose the guest data" or
/// "use a different address". The UI must say that plainly.
final class EmailAlreadyRegisteredFailure extends Failure {
  const EmailAlreadyRegisteredFailure({required this.email, super.cause});
  final String email;
}

/// OS-level permission denied — calendar, notifications.
final class PermissionFailure extends Failure {
  const PermissionFailure({required this.permission, super.cause});
  final String permission;
}

/// Server-side quota exhausted (e.g. AI runs this month).
final class QuotaFailure extends Failure {
  const QuotaFailure({
    required this.limit,
    required this.resetsAt,
    super.cause,
  });
  final int limit;
  final DateTime resetsAt;
}

/// The user's plan does not include this feature.
///
/// Has exactly one UI treatment: the paywall sheet. Never an error state.
final class EntitlementFailure extends Failure {
  const EntitlementFailure({required this.feature, super.cause});
  final String feature;
}

final class ValidationFailure extends Failure {
  const ValidationFailure({required this.message, this.field, super.cause});
  final String message;
  final String? field;
}

final class ServerFailure extends Failure {
  const ServerFailure({this.code, super.cause, super.stackTrace});
  final String? code;
}
