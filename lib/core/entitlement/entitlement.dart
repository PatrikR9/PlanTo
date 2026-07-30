import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../network/supabase_providers.dart';

/// What the user is entitled to.
///
/// Read from the `plan` custom claim on the JWT, set server-side by an auth
/// hook. Reading it from the token rather than a table means every Pro gate is
/// free of a database round-trip.
///
/// SECURITY: this is a UI convenience only. The authoritative check lives in
/// the Edge Functions, which read the same claim from the verified token. A
/// tampered client can flip this flag and still get a 403 (architecture
/// section 13.1).
enum Plan { free, pro }

class Entitlement {
  const Entitlement({required this.plan, required this.aiPreviewUsed});

  final Plan plan;
  final bool aiPreviewUsed;

  bool get isPro => plan == Plan.pro;

  /// Free users get exactly one lifetime AI run so they can see what they
  /// would be paying for (architecture section 11.6).
  bool get canUseAi => isPro || !aiPreviewUsed;

  static const Entitlement free =
      Entitlement(plan: Plan.free, aiPreviewUsed: false);
}

final Provider<Entitlement> entitlementProvider =
    Provider<Entitlement>((Ref ref) {
  final Session? session = ref.watch(sessionProvider);
  if (session == null) return Entitlement.free;

  final Map<String, dynamic> claims = session.user.appMetadata;
  final String plan = claims['plan'] as String? ?? 'free';

  return Entitlement(
    plan: plan == 'pro' ? Plan.pro : Plan.free,
    aiPreviewUsed:
        (session.user.userMetadata?['ai_preview_used'] as bool?) ?? false,
  );
});
