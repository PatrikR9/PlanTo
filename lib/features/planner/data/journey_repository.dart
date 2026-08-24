import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
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
          // invoke() hodí FunctionException na 4xx a error_mapper z ní vytáhne
          // větu, kterou funkce napsala — „odjezd je v minulosti" a „cíl
          // neznáme" si zaslouží různé reakce.
          final FunctionResponse res = await _client.functions.invoke(
            'transport-search',
            body: query.toWire(tripId, groupSize: groupSize),
          );
          final Object? data = res.data;
          if (data is! Map) return const JourneySearch.empty();
          return JourneySearch.fromWire(Map<String, dynamic>.from(data));
        },
      );
}

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
