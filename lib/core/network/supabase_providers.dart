import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/env/env.dart';

/// The Supabase client, or null when the app runs without a backend.
///
/// Nullable on purpose: local-only mode is a supported dev state, and making
/// every consumer acknowledge it is better than a late null-check crash.
final Provider<SupabaseClient?> supabaseClientProvider =
    Provider<SupabaseClient?>((Ref ref) {
  if (!Env.isConfigured) return null;
  return Supabase.instance.client;
});

/// Auth state as a stream. The router listens to this for redirects.
final StreamProvider<AuthState> authStateProvider =
    StreamProvider<AuthState>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const Stream<AuthState>.empty();
  return client.auth.onAuthStateChange;
});

/// Current session, or null. Synchronous — safe to read inside a redirect.
final Provider<Session?> sessionProvider = Provider<Session?>((Ref ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseClientProvider)?.auth.currentSession;
});

/// True for anonymous sessions. Anonymous users may join trips but may not
/// create them or use AI (architecture section 10.4).
final Provider<bool> isAnonymousProvider = Provider<bool>((Ref ref) {
  return ref.watch(sessionProvider)?.user.isAnonymous ?? false;
});
