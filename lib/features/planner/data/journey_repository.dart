import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
import '../../../core/error/failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/journey.dart';
import '../domain/plan_context.dart';

/// Vyhledání spojení.
///
/// Jde přes Edge Function `transport-search`, nikdy přímo na poskytovatele.
/// Tři důvody, a všechny tři jsou strukturální:
///
///   * v aplikaci nejsou žádné klíče, protože tam nemají jak být;
///   * cache i rate limit jsou sdílené, takže pětičlenná skupina otevírající
///     jednu obrazovku nevyrobí pět stejných dotazů na komunitní službu;
///   * klient nikdy nevidí JSON Transitousu, takže výměna poskytovatele je
///     práce v Edge Function a v [Journey.fromWire], ne refaktoring.
///
/// Cesta tam a cesta zpět jsou dvě samostatná volání s vlastním
/// [JourneyQuery.direction]. Obrátit itinerář by byl vymyšlený jízdní řád:
/// odpolední spoje jezdí jinak často než ranní a v neděli úplně jinak.
abstract interface class JourneyRepository {
  Future<JourneySearch> search(
    String tripId,
    JourneyQuery query, {
    int groupSize,
  });
}

class SupabaseJourneyRepository implements JourneyRepository {
  const SupabaseJourneyRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<JourneySearch> search(
    String tripId,
    JourneyQuery query, {
    int groupSize = 1,
  }) =>
      guard(
        // Routing přes cizí službu má vlastní timeout dvanáct vteřin a nad ním
        // ještě běh funkce. Dvacet vteřin z guard() by uřízlo odpověď, která
        // by za tři další dorazila.
        timeout: kSlowRequestTimeout,
        () async {
          try {
            final FunctionResponse res = await _client.functions.invoke(
              'transport-search',
              body: query.toWire(tripId, groupSize: groupSize),
            );
            final Object? data = res.data;
            if (data is! Map) return const JourneySearch.empty();
            return JourneySearch.fromWire(Map<String, dynamic>.from(data));
          } on FunctionException catch (e) {
            // Kód, ne věta serveru (architektura §12.3). `error_mapper` by
            // z toho vytáhl `departure is in the past` — pravdu, se kterou
            // uživatel nic neudělá.
            throw ValidationFailure(
              message: _sentenceFor(_codeOf(e.details)),
              field: 'transport',
              cause: e,
            );
          }
        },
      );
}

/// Stabilní kód z obálky `{ "error": { "code": … } }`.
String? _codeOf(Object? details) {
  final Object? error = details is Map ? details['error'] : null;
  final Object? code = error is Map ? error['code'] : null;
  return code?.toString();
}

/// Česká věta ke kódu. Každá z nich musí uživateli říct, co udělat dál —
/// „nepovedlo se to" je hláška, po které zbývá jenom zavřít aplikaci.
String _sentenceFor(String? code) => switch (code) {
      'DEPARTURE_IN_THE_PAST' =>
        'Termín výletu už proběhl, takže pro něj žádné spoje nenajdeme — '
            'jízdní řády do minulosti nesahají. Vyberte v Termínech nové datum.',
      'DEPARTURE_TOO_FAR' =>
        'Na tak vzdálený termín jízdní řády ještě nevyšly. Spoje se dají '
            'hledat zhruba dva měsíce dopředu; zkuste to blíž k výletu.',
      'INVALID_ORIGIN' =>
        'Výlet nemá odkud vyjet. Doplňte výchozí zastávku v úpravách výletu.',
      'INVALID_DESTINATION' =>
        'Cíl výletu nemá polohu, ke které by šlo hledat spojení. Vyberte ho '
            'znovu ze seznamu zastávek.',
      'INVALID_DATETIME' =>
        'Čas odjezdu se nepodařilo přečíst. Zkuste plán sestavit znovu.',
      'UNAUTHORIZED' => 'Přihlaste se prosím znovu.',
      _ => 'Spojení se nepodařilo vyhledat. Zkuste to prosím za chvíli.',
    };

/// Bez backendu se nehledá nic — a je to prázdný výsledek, ne výjimka.
///
/// Prázdno umí plán zpracovat: řekne „spojení se nenašlo". Výjimka by
/// v lokálním režimu udělala z celé záložky červený pruh.
class UnconfiguredJourneyRepository implements JourneyRepository {
  const UnconfiguredJourneyRepository();

  @override
  Future<JourneySearch> search(
    String tripId,
    JourneyQuery query, {
    int groupSize = 1,
  }) async =>
      const JourneySearch.empty();
}

final Provider<JourneyRepository> journeyRepositoryProvider =
    Provider<JourneyRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredJourneyRepository();
  return SupabaseJourneyRepository(client);
});
