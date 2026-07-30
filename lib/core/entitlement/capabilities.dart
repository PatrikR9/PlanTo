import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/env/env.dart';
import '../network/supabase_providers.dart';

/// Can this user start a trip?
///
/// Anonymous accounts may join trips but not create them: creation is the
/// abuse surface (architecture section 10.4). Without a backend everything is
/// permitted, because local-only mode exists precisely so screens can be
/// reviewed — hiding half the UI there would defeat the point.
final Provider<bool> canCreateTripProvider = Provider<bool>((Ref ref) {
  if (!Env.isConfigured) return true;
  return ref.watch(sessionProvider) != null && !ref.watch(isAnonymousProvider);
});

/// True when the user is signed in but as a guest — the state that needs
/// explaining rather than silently removing buttons.
final Provider<bool> needsAccountUpgradeProvider = Provider<bool>((Ref ref) {
  if (!Env.isConfigured) return false;
  return ref.watch(isAnonymousProvider);
});
