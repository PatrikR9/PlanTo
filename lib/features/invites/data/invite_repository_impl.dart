import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/env/env.dart';
import '../../../core/error/error_mapper.dart';
import '../../../core/error/failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/invite.dart';

/// Public base for invite links. Must match the App Links host in
/// AndroidManifest.xml.
const String kInviteBase = 'https://planto.app/i';

class SupabaseInviteRepository implements InviteRepository {
  const SupabaseInviteRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<InvitePreview?> preview(String token) => guard(() async {
        final List<dynamic> rows = await _client.rpc<List<dynamic>>(
          'preview_invite',
          params: <String, dynamic>{'p_token': token},
        );
        if (rows.isEmpty) return null;

        final Map<String, dynamic> r = rows.first as Map<String, dynamic>;
        return InvitePreview(
          tripId: r['trip_id'] as String,
          title: r['title'] as String,
          originLabel: r['origin_label'] as String,
          windowStart: DateTime.parse(r['window_start'] as String).toLocal(),
          windowEnd: DateTime.parse(r['window_end'] as String).toLocal(),
          durationDays: (r['duration_days'] as int?) ?? 1,
          participantCount: (r['participant_count'] as int?) ?? 0,
          organiserName: (r['organiser_name'] as String?) ?? 'Organizátor',
          alreadyMember: (r['already_member'] as bool?) ?? false,
        );
      });

  @override
  Future<String> redeem(String token) => guard(() async {
        final dynamic id = await _client.rpc<dynamic>(
          'redeem_invite',
          params: <String, dynamic>{'p_token': token},
        );
        return id as String;
      });

  @override
  Future<String> createLink(String tripId) => guard(() async {
        final dynamic token = await _client.rpc<dynamic>(
          'create_invite',
          params: <String, dynamic>{'p_trip': tripId},
        );
        return '$kInviteBase/${token as String}';
      });

  @override
  Future<void> revokeLinks(String tripId) => guard(
        () => _client.rpc<void>(
          'revoke_invite',
          params: <String, dynamic>{'p_trip': tripId},
        ),
      );
}

class UnconfiguredInviteRepository implements InviteRepository {
  const UnconfiguredInviteRepository();
  Never _fail() => throw const ServerFailure(code: 'NO_BACKEND');

  @override
  Future<InvitePreview?> preview(String token) async => null;
  @override
  Future<String> redeem(String token) async => _fail();
  @override
  Future<String> createLink(String tripId) async => _fail();
  @override
  Future<void> revokeLinks(String tripId) async {}
}

final Provider<InviteRepository> inviteRepositoryProvider =
    Provider<InviteRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null || !Env.isConfigured) {
    return const UnconfiguredInviteRepository();
  }
  return SupabaseInviteRepository(client);
});

final FutureProviderFamily<InvitePreview?, String> invitePreviewProvider =
    FutureProvider.family<InvitePreview?, String>((Ref ref, String token) {
  return ref.watch(inviteRepositoryProvider).preview(token);
});
