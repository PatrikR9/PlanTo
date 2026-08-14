import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/env/env.dart';
import '../../../core/error/error_mapper.dart';
import '../../../core/error/failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/google_calendar.dart';

abstract interface class GoogleCalendarRepository {
  /// Připojený účet, nebo null. Token nikdy.
  Future<GoogleAccount?> account();

  /// Načte obsazenost do výletu a zapíše ji.
  ///
  /// [code] se posílá jen napoprvé, hned po návratu z obrazovky souhlasu.
  /// Podruhé a dál si funkce vystačí s uloženým refresh tokenem — proto se
  /// uživatel neptá znovu při každém výletu.
  Future<void> sync(String tripId, {String? code});

  /// Smaže účet i bloky, které vyrobil. Okamžitě, bez lhůty.
  Future<void> disconnect();
}

class SupabaseGoogleCalendarRepository implements GoogleCalendarRepository {
  const SupabaseGoogleCalendarRepository(this._client, this._redirectUri);

  final SupabaseClient _client;

  /// Musí se doslova shodovat s tím, co šlo do obrazovky souhlasu — Google to
  /// při výměně kódu porovnává znak po znaku, včetně koncového lomítka. Proto
  /// obojí pochází z jednoho `Env.oauthRedirectUri`.
  final String _redirectUri;

  @override
  Future<GoogleAccount?> account() => guard(() async {
        final List<dynamic> rows =
            await _client.rpc<List<dynamic>>('my_google_calendar');
        if (rows.isEmpty) return null;
        return GoogleAccount.fromRow(rows.first as Map<String, dynamic>);
      });

  @override
  Future<void> sync(String tripId, {String? code}) => guard(
        // Výměna kódu, dotaz do Googlu a zápis v jednom volání. Google odpovídá
        // v desetinách sekundy, ale token endpoint umí být pomalý a dvacet
        // vteřin z guard() je na to málo.
        timeout: kSlowRequestTimeout,
        () async {
          // invoke() hodí FunctionException na 4xx a error_mapper z ní vytáhne
          // větu, kterou funkce napsala. „Souhlas byl odvolán" a „kalendář se
          // nepodařilo přečíst" se tak nesloučí do jedné hlášky.
          await _client.functions.invoke(
            'google-calendar',
            body: <String, dynamic>{
              'trip_id': tripId,
              if (code != null) 'code': code,
              if (code != null) 'redirect_uri': _redirectUri,
            },
          );
        },
      );

  @override
  Future<void> disconnect() => guard(() async {
        await _client.rpc<void>('disconnect_google_calendar');
      });
}

class UnconfiguredGoogleCalendarRepository implements GoogleCalendarRepository {
  const UnconfiguredGoogleCalendarRepository();
  Never _fail() => throw const ServerFailure(code: 'NO_BACKEND');

  @override
  Future<GoogleAccount?> account() async => null;
  @override
  Future<void> sync(String tripId, {String? code}) async => _fail();
  @override
  Future<void> disconnect() async => _fail();
}

final Provider<GoogleCalendarRepository> googleCalendarRepositoryProvider =
    Provider<GoogleCalendarRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredGoogleCalendarRepository();
  return SupabaseGoogleCalendarRepository(client, Env.oauthRedirectUri);
});

/// Připojený účet. Rodina není potřeba — účet patří člověku, ne výletu, a
/// každý výlet, do kterého se zapojí, ho použije znovu.
final FutureProvider<GoogleAccount?> googleAccountProvider =
    FutureProvider<GoogleAccount?>((Ref ref) {
  return ref.watch(googleCalendarRepositoryProvider).account();
});
