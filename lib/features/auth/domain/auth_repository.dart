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

  /// Zakládá účet heslem.
  ///
  /// Vrací `true`, když je hotovo a člověk je přihlášený, a `false`, když
  /// Supabase čeká na potvrzení e-mailu. O tom rozhoduje přepínač *Confirm
  /// email* v dashboardu, ne tenhle kód — proto je to návratová hodnota a ne
  /// konstanta. Dokud SMTP nefunguje, běží to s potvrzením vypnutým a projde
  /// první větev; až bude fungovat, druhá. Aplikace se nemění.
  Future<bool> signUpWithPassword({
    required String email,
    required String password,
  });

  /// Přihlašuje heslem. Pro člověka, který už účet má, je to jediný krok
  /// a nepotřebuje k němu doručený e-mail.
  Future<void> signInWithPassword({
    required String email,
    required String password,
  });

  /// Pošle odkaz na změnu zapomenutého hesla.
  ///
  /// Tohle e-mail potřebuje vždycky a nejde to obejít — bez doručení není jak
  /// ověřit, že schránka patří tomu, kdo o reset žádá.
  Future<void> sendPasswordReset(String email);

  /// Browser-based Google OAuth.
  Future<void> signInWithGoogle();

  /// Upgrades an anonymous account in place, keeping the same user id so no
  /// trip membership or availability data has to be migrated.
  Future<void> linkGoogle();

  Future<void> signOut();

  /// The name the rest of the group sees.
  ///
  /// A guest arrives as "Cestovatel" — the fallback in handle_new_user, which
  /// is the only thing the database can invent when there is no email and no
  /// OAuth profile. Three people called Cestovatel on a Dates tab is not a
  /// group decision, it is a puzzle.
  Future<String?> myDisplayName();

  Future<void> setDisplayName(String name);
}

/// The placeholder handle_new_user falls back to. Anyone still carrying it
/// has never told us who they are, which is exactly when to ask.
const String kAnonymousDisplayName = 'Cestovatel';
