import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth_repository_impl.dart';
import '../../domain/auth_repository.dart';

/// Owns the sign-in mutation state.
///
/// The screen never calls the repository directly and never holds a try/catch:
/// AsyncValue.guard funnels every failure into `state`, and the UI renders it
/// from one place.
class SignInController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  Future<bool> sendCode(String email) async {
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(() => _repo.sendEmailOtp(email));
    return !state.hasError;
  }

  Future<bool> verifyCode({required String email, required String code}) async {
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(
      () => _repo.verifyEmailOtp(email: email, token: code),
    );
    return !state.hasError;
  }

  Future<bool> google() async {
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(_repo.signInWithGoogle);
    return !state.hasError;
  }

  Future<bool> continueAsGuest() async {
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(_repo.signInAnonymously);
    return !state.hasError;
  }

  /// Abandons the guest session and signs in to the account that already owns
  /// this address.
  ///
  /// There is no merge: Supabase cannot fold an anonymous user into an
  /// existing one, so anything the guest joined stays with the guest account.
  /// The screen warns about that before calling this.
  Future<bool> switchToExistingAccount(String email) async {
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(() async {
      await _repo.signOut();
      await _repo.sendEmailOtp(email);
    });
    return !state.hasError;
  }

  Future<void> signOut() async {
    state = const AsyncLoading<void>();
    state = await AsyncValue.guard(_repo.signOut);
  }
}

final AsyncNotifierProvider<SignInController, void> signInControllerProvider =
    AsyncNotifierProvider<SignInController, void>(SignInController.new);

/// Very deliberately permissive: rejecting a valid address is far worse than
/// letting a typo through, because the code simply will not arrive.
bool isPlausibleEmail(String value) {
  final String v = value.trim();
  return v.length >= 5 && v.contains('@') && v.split('@').last.contains('.');
}
