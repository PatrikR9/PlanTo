/// Compile-time configuration. Values arrive via --dart-define-from-file so
/// nothing sensitive is committed and every flavour builds from one source.
///
/// The Supabase anon key is public by design — it ships inside the app bundle
/// and that is fine, because RLS is what protects the data. It is not a
/// secret, but it is also not a licence to skip policies. No third-party API
/// key ever appears here; those live only in Edge Function secrets.
enum Flavour { dev, stg, prod }

abstract final class Env {
  static const String _flavour =
      String.fromEnvironment('FLAVOUR', defaultValue: 'dev');

  static Flavour get flavour => switch (_flavour) {
        'prod' => Flavour.prod,
        'stg' => Flavour.stg,
        _ => Flavour.dev,
      };

  static const String _rawSupabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String _rawSupabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Oříznuté, a je to tu kvůli jednomu konkrétnímu večeru.
  ///
  /// APK sestavené v CI hlásilo na telefonu:
  ///
  ///     Failed host lookup: 'dehgpsnemmemnxbhujai.supabase.co'
  ///     OS Error: No address associated with hostname
  ///
  /// Ten hostname je správně. Jenže hodnota přišla z GitHub secretu, do
  /// kterého se při vložení dostal konec řádku — a mezera nebo `\n` na konci
  /// URL je v poli neviditelná, v chybové hlášce neviditelná taky, a přesto
  /// z ní udělá doménu, která neexistuje. Jediné, co je vidět, je že adresa
  /// vypadá naprosto v pořádku a stejně se nepřeloží.
  ///
  /// `env/*.json` tímhle trpět nemůže, protože v JSONu se konec řádku uvnitř
  /// řetězce napsat nedá. Postihuje to jen cestu přes secrets, tedy přesně tu,
  /// kterou se staví buildy pro testery.
  static String get supabaseUrl => _rawSupabaseUrl.trim();
  static String get supabaseAnonKey => _rawSupabaseAnonKey.trim();

  /// Whether a backend is wired up.
  ///
  /// When false the app still runs, in a local-only mode with a visible
  /// banner. This exists so UI work is never blocked on backend setup — you
  /// can build and review screens before the Supabase project exists.
  /// Production builds refuse to start unconfigured (see [assertConfigured]).
  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static String get appName => switch (flavour) {
        Flavour.prod => 'PlanTo',
        Flavour.stg => 'PlanTo (stg)',
        Flavour.dev => 'PlanTo (dev)',
      };

  static bool get isProd => flavour == Flavour.prod;

  /// Where invite links point.
  ///
  /// GitHub Pages while planto.app does not exist. Configurable rather than
  /// hard-coded because it appears in shared links: once a link is in a group
  /// chat it lives forever, so the value has to be swappable per build without
  /// touching code.
  static const String inviteBase = String.fromEnvironment(
    'INVITE_BASE',
    defaultValue: 'https://patrikr9.github.io/PlanTo/i',
  );

  /// Google sign-in needs an OAuth client in Google Cloud plus the provider
  /// switched on in Supabase. Until both exist the button is hidden rather
  /// than shown and broken — a dead button costs more trust than a missing one.
  static const bool googleEnabled = bool.fromEnvironment('GOOGLE_SIGN_IN');

  /// OAuth client for reading calendar availability from Google.
  ///
  /// Public by design — it travels in the authorisation URL, which is why it
  /// can live in the app at all. The matching secret exists only as an Edge
  /// Function secret; the client never sees it and never exchanges the code
  /// itself.
  ///
  /// Same rule as [googleEnabled]: an empty value hides the button. The one
  /// thing worse than a missing way to connect a calendar is one that opens
  /// a Google error page.
  /// Oříznuté ze stejného důvodu jako [supabaseUrl], a byla to tu chyba:
  /// kontrola `.trim().isNotEmpty` ořezanou hodnotu ověřila, ale ven se
  /// posílala neořezaná. Konec řádku, který se do GitHub secretu dostane při
  /// vložení, je v poli neviditelný, v URL neviditelný taky — a Google na něj
  /// odpoví `invalid_client: The OAuth client was not found`, což vypadá jako
  /// smazaný klient, ne jako bílý znak.
  static const String _rawGoogleCalendarClientId =
      String.fromEnvironment('GOOGLE_CALENDAR_CLIENT_ID');

  static String get googleCalendarClientId => _rawGoogleCalendarClientId.trim();

  static bool get googleCalendarEnabled => googleCalendarClientId.isNotEmpty;

  /// Where Google sends the browser back. A static page next to the invite
  /// landing page, not a route in the app: Google rejects custom schemes for
  /// a Web-application client, and that client type is the only one with a
  /// secret. The page forwards the code onwards — see docs/oauth.html.
  ///
  /// Derived from [inviteBase] so the two can never drift apart: both live on
  /// the same host, and moving to planto.app changes one define, not two.
  static String get oauthRedirectUri {
    final String base = inviteBase.endsWith('/i')
        ? inviteBase.substring(0, inviteBase.length - 2)
        : '$inviteBase/';
    return '${base}oauth.html';
  }

  /// Supabase free-tier projects on the built-in mailer cannot edit their auth
  /// templates (since 3 June 2026), so the email contains a magic LINK, not a
  /// 6-digit code. Flip this to true via --dart-define once custom SMTP is
  /// configured and the template uses {{ .Token }}; the code-entry screen is
  /// already built and wired.
  static const bool emailUsesOtpCode = bool.fromEnvironment('EMAIL_OTP_CODE');

  /// A release build with no backend is always a mistake, so fail loudly.
  /// In dev it is a legitimate state, so only warn.
  static void assertConfigured() {
    if (!isConfigured && isProd) {
      throw StateError(
        'SUPABASE_URL / SUPABASE_ANON_KEY missing in a prod build. '
        'Run with --dart-define-from-file=env/prod.json',
      );
    }
  }
}
