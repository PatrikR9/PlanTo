import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/error_mapper.dart';
import '../../../core/error/failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../domain/plan_context.dart';
import '../domain/trip_plan.dart';

/// Uložení a načtení plánu.
///
/// Celý plán najednou, jedním RPC. Replanning mění několik položek současně a
/// částečně uložený plán by byl horší než neuložený — časová osa, kde nová
/// cesta zpět navazuje na starou aktivitu, vypadá platně.
///
/// Persistuje se doménový stav, ne odpověď vyhledávače. Po roce a po výměně
/// poskytovatele musí být pořád vidět, co uživatel změnil, co je zamčené,
/// který spoj si vybral a co smí engine přepočítat.
abstract interface class PlanRepository {
  /// Null znamená „plán ještě není". To je normální stav výletu, ne chyba.
  Future<TripPlan?> load(String tripId);

  /// Fakta, na kterých plán stojí — odkud, kam, který den, jak dlouhý den a
  /// hlavně posun časové zóny výletu. Jedno volání, protože engine je
  /// potřebuje všechna současně a pět dotazů by šlo zastihnout v půlce.
  Future<PlanContextResult> context(String tripId);

  /// Vrací uložený plán i s novou revizí — klient tak nemusí hádat, co server
  /// přidělil za ID nově vzniklým položkám.
  Future<TripPlan> save(TripPlan plan);

  Future<void> reset(String tripId);
}

/// Plán mezitím změnil někdo jiný.
///
/// Vlastní SQLSTATE, ne obecná chyba: tohle je jediný případ, kdy klient nemá
/// zkoušet znovu, ale znovu načíst. Kdyby to spadlo do [ServerFailure],
/// nabídla by obrazovka „Zkusit znovu" — a to by cizí změnu přepsalo.
const String kPlanConflictCode = 'P0409';

/// Kontext plus důvod, proč případně chybí.
///
/// Dvě různé prázdnoty: „ještě není zamčený termín" a „ještě není cíl" vedou
/// na dvě různé obrazovky a jeden null by je slil do jedné.
class PlanContextResult {
  const PlanContextResult(this.context, this.gap);

  final PlanContext? context;
  final PlanContextGap gap;
}

class SupabasePlanRepository implements PlanRepository {
  const SupabasePlanRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<TripPlan?> load(String tripId) => guard(() async {
        final Object? row = await _client.rpc<Object?>(
          'trip_plan',
          params: <String, dynamic>{'p_trip': tripId},
        );
        if (row is! Map) return null;
        return TripPlan.fromWire(tripId, Map<String, dynamic>.from(row));
      });

  @override
  Future<PlanContextResult> context(String tripId) => guard(() async {
        final Object? row = await _client.rpc<Object?>(
          'trip_plan_context',
          params: <String, dynamic>{'p_trip': tripId},
        );
        if (row is! Map) {
          return const PlanContextResult(null, PlanContextGap.noDate);
        }
        final Map<String, dynamic> map = Map<String, dynamic>.from(row);
        return PlanContextResult(
          PlanContext.fromWire(map),
          PlanContext.gapOf(map),
        );
      });

  @override
  Future<TripPlan> save(TripPlan plan) => guard(() async {
        try {
          final Object? row = await _client.rpc<Object?>(
            'save_trip_plan',
            params: <String, dynamic>{
              'p_trip': plan.tripId,
              'p_plan': plan.toWire(),
              // Null u prvního uložení: klient tím říká „vím, že zakládám".
              'p_revision': plan.id == null ? null : plan.revision,
            },
          );
          if (row is! Map) {
            throw const ServerFailure(code: 'PLAN_SAVE_EMPTY');
          }
          return TripPlan.fromWire(
            plan.tripId,
            Map<String, dynamic>.from(row),
          );
        } on PostgrestException catch (e) {
          if (e.code == kPlanConflictCode) {
            throw const ValidationFailure(
              message: 'Plán mezitím změnil někdo jiný ve skupině. '
                  'Načtěte ho znovu, ať se změny nepřepíšou.',
              field: 'plan',
            );
          }
          rethrow;
        }
      });

  @override
  Future<void> reset(String tripId) => guard(() async {
        await _client.rpc<void>(
          'reset_trip_plan',
          params: <String, dynamic>{'p_trip': tripId},
        );
      });
}

class UnconfiguredPlanRepository implements PlanRepository {
  const UnconfiguredPlanRepository();

  @override
  Future<TripPlan?> load(String tripId) async => null;

  @override
  Future<PlanContextResult> context(String tripId) async =>
      const PlanContextResult(null, PlanContextGap.noDate);

  @override
  Future<TripPlan> save(TripPlan plan) async =>
      throw const ServerFailure(code: 'NO_BACKEND');

  @override
  Future<void> reset(String tripId) async =>
      throw const ServerFailure(code: 'NO_BACKEND');
}

final Provider<PlanRepository> planRepositoryProvider =
    Provider<PlanRepository>((Ref ref) {
  final SupabaseClient? client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnconfiguredPlanRepository();
  return SupabasePlanRepository(client);
});
