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
            emailRedirectTo: kIsWeb ? null : kOAuthRedirect,
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
          emailRedirectTo: kIsWeb ? null : kOAuthRedirect,
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
                redirectTo: kIsWeb ? null : kOAuthRedirect,
              )
            : _client.auth.signInWithOAuth(
                OAuthProvider.google,
                // On web Supabase returns to the current origin; on Android it
                // needs the app's own scheme.
                redirectTo: kIsWeb ? null : kOAuthRedirect,
              ),
      );

  @override
  Future<void> linkGoogle() => guard(
        () => _client.auth.linkIdentity(
          OAuthProvider.google,
          redirectTo: kIsWeb ? null : kOAuthRedirect,
        ),
      );

  @override
  Future<void> signOut() => guard(() => _client.auth.signOut());
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
  Future<void> verifyEmailOtp(
          {required String email, required String token,}) async =>
      _fail();
  @override
  Future<void> signInWithGoogle() async => _fail();
  @override
  Future<void> linkGoogle() async => _fail();
  @override
  Future<void> signOut() async {}
}

final Provider<AuthRepository> authRepositoryProvider =
    Provider<AuthRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredAuthRepository();
  return SupabaseAuthRepository(client);
});
