import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
import '../../../core/error/failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/auth_repository.dart';

/// Deep link Supabase redirects back to after an OAuth round trip.
/// Must match the intent filter in android/app/src/main/AndroidManifest.xml
/// and the redirect allowlist in the Supabase dashboard.
const String kOAuthRedirect = 'app.planto://login-callback/';

/// Where an auth link must come back to.
///
/// Passing `null` on the web does NOT mean "return to the current origin",
/// which is what the code here used to assume. It means Supabase falls back
/// to the project's **Site URL** — one fixed value, which cannot be both
/// `http://localhost:50350/` during development and the Pages URL in
/// production. So the magic link landed on whichever of the two was
/// configured, and for the other one the page simply never appeared.
///
/// The app states its own address instead. `Uri.base` carries the real path
/// even under the hash URL strategy, because the route lives in the fragment.
///
/// Both addresses have to be listed in Supabase → Authentication → URL
/// Configuration → Redirect URLs, or the link is rewritten to the Site URL
/// and we are back where we started.
String get authRedirect =>
    kIsWeb ? '${Uri.base.origin}${Uri.base.path}' : kOAuthRedirect;

class SupabaseAuthRepository implements AuthRepository {
  const SupabaseAuthRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<void> signInAnonymously() =>
      guard(() => _client.auth.signInAnonymously());

  /// True when the current session is a guest that should be upgraded rather
  /// than replaced. Signing a guest in normally would mint a NEW user id and
  /// silently orphan every trip they had already joined.
  bool get _isGuest => _client.auth.currentUser?.isAnonymous ?? false;

  @override
  Future<void> sendEmailOtp(String email) => guard(() async {
        if (_isGuest) {
          // Converting an anonymous account: attach the address to the
          // existing user instead of creating a second one.
          await _client.auth.updateUser(
            UserAttributes(email: email.trim()),
            emailRedirectTo: authRedirect,
          );
          return;
        }
        await _client.auth.signInWithOtp(
          email: email.trim(),
          shouldCreateUser: true,
          // Since 3 June 2026 a free-tier project on Supabase's built-in
          // mailer cannot edit its auth email templates, so the mail contains
          // a magic LINK, not a 6-digit code. Setting emailRedirectTo makes
          // that link land back in the app, so the flow still completes:
          // on web supabase_flutter picks the session out of the URL, on
          // Android the deep link does it. Once custom SMTP is configured the
          // template can be switched to {{ .Token }} and the code entry
          // screen becomes the primary path — no code change needed, both
          // work simultaneously.
          emailRedirectTo: authRedirect,
        );
      });

  @override
  Future<void> verifyEmailOtp({
    required String email,
    required String token,
  }) =>
      guard(
        () => _client.auth.verifyOTP(
          email: email.trim(),
          token: token.trim(),
          // A guest confirming a newly attached address is an email CHANGE,
          // not a sign-in. Using the wrong type here fails with a confusing
          // "token expired".
          type: _isGuest ? OtpType.emailChange : OtpType.email,
        ),
      );

  @override
  Future<void> signInWithGoogle() => guard(
        () => _isGuest
            // Same reasoning as email: link, do not replace.
            ? _client.auth.linkIdentity(
                OAuthProvider.google,
                redirectTo: authRedirect,
              )
            : _client.auth.signInWithOAuth(
                OAuthProvider.google,
                redirectTo: authRedirect,
              ),
      );

  @override
  Future<void> linkGoogle() => guard(
        () => _client.auth.linkIdentity(
          OAuthProvider.google,
          redirectTo: authRedirect,
        ),
      );

  @override
  Future<void> signOut() => guard(() => _client.auth.signOut());

  // Straight through PostgREST rather than an RPC: profiles_write_self
  // already restricts the row to its owner, and the column-level grant
  // already restricts which columns can be written — `plan` is not one of
  // them, which is the thing that actually mattered.
  @override
  Future<String?> myDisplayName() => guard(() async {
        final String? uid = _client.auth.currentUser?.id;
        if (uid == null) return null;
        final Map<String, dynamic>? row = await _client
            .from('profiles')
            .select('display_name')
            .eq('id', uid)
            .maybeSingle();
        return row?['display_name'] as String?;
      });

  @override
  Future<void> setDisplayName(String name) => guard(() async {
        final String? uid = _client.auth.currentUser?.id;
        if (uid == null) return;
        await _client.from('profiles').update(
            <String, dynamic>{'display_name': name.trim()}).eq('id', uid);
      });
}

/// Fails every call with a clear message when no backend is configured, so
/// local-only mode degrades honestly instead of throwing a null error.
class UnconfiguredAuthRepository implements AuthRepository {
  const UnconfiguredAuthRepository();

  Never _fail() => throw const ServerFailure(code: 'NO_BACKEND');

  @override
  Future<void> signInAnonymously() async => _fail();
  @override
  Future<void> sendEmailOtp(String email) async => _fail();
  @override
  Future<void> verifyEmailOtp({
    required String email,
    required String token,
  }) async =>
      _fail();
  @override
  Future<void> signInWithGoogle() async => _fail();
  @override
  Future<void> linkGoogle() async => _fail();
  @override
  Future<void> signOut() async {}
  @override
  Future<String?> myDisplayName() async => null;
  @override
  Future<void> setDisplayName(String name) async {}
}

final Provider<AuthRepository> authRepositoryProvider =
    Provider<AuthRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredAuthRepository();
  return SupabaseAuthRepository(client);
});
