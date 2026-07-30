/// What the app needs from an identity provider — nothing more.
///
/// Keeping this interface in `domain` means controllers and screens never
/// import supabase_flutter, so swapping the provider (or faking it in a test)
/// touches one file.
abstract interface class AuthRepository {
  /// Signs in without an account. Used when an invitee opens a trip link:
  /// the join flow must not begin with a signup wall (architecture section 10.2).
  Future<void> signInAnonymously();

  /// Sends a 6-digit code. Preferred over magic links: no app switching, and
  /// it works when the mail app opens in a different browser.
  Future<void> sendEmailOtp(String email);

  /// Exchanges the code for a session.
  Future<void> verifyEmailOtp({required String email, required String token});

  /// Browser-based Google OAuth.
  Future<void> signInWithGoogle();

  /// Upgrades an anonymous account in place, keeping the same user id so no
  /// trip membership or availability data has to be migrated.
  Future<void> linkGoogle();

  Future<void> signOut();
}
