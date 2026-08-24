/// Proč plán nevyšel, nebo v čem si odporuje.
///
/// Kódy, ne věty — stejně jako všude jinde v projektu. Českou formulaci
/// skládá prezentační vrstva, protože jenom ona ví, jak se jmenuje ta
/// aktivita a v jakém pádu má být.
///
/// Existence tohohle typu je půlka požadavku na replanning: „nenašel jsem
/// spoj" musí umět aplikace říct nahlas. Tichý přepočet, který skončí jinak,
/// než uživatel chtěl, je horší než chyba — chyba je aspoň vidět.
library;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

enum PlanProblemCode {
  /// Pro zadaný požadavek na příjezd se nenašlo žádné spojení.
  noOutboundFound('no_outbound_found'),

  /// Pro návrat do deadlinu se nenašlo žádné spojení. `earliest` nese
  /// nejbližší možný návrat, když nějaký je — bez něj je hláška slepá ulička.
  noReturnFound('no_return_found'),

  /// Skupina dorazí až po začátku zamčené aktivity.
  arrivalAfterActivity('arrival_after_activity'),

  /// Skupina dorazí do cíle později, než uživatel chtěl. Spoj se našel,
  /// jenom nestíhá — to je jiná informace než „nic jsem nenašel".
  arrivalAfterRequest('arrival_after_request'),

  /// Ručně vybraný spoj byl nahrazen, protože nové zadání s ním nešlo
  /// splnit. Nahrazený spoj se **nesmí** vyměnit potichu, proto tenhle kód.
  userChoiceReplaced('user_choice_replaced'),

  /// Návrat domů je po deadlinu, který uživatel nastavil.
  returnAfterDeadline('return_after_deadline'),

  /// Přepočet by musel posunout zamčenou položku. Neposunul ji.
  lockedConflict('locked_conflict'),

  /// Dvě položky se překrývají v čase.
  overlap('overlap'),

  /// Plán nejde postavit, dokud není zamčený termín.
  noDate('no_date'),

  /// Plán nejde postavit, dokud není cíl s polohou.
  noDestination('no_destination'),

  /// Časy jsou geometrický odhad, ne jízdní řád.
  noTimetable('no_timetable');

  const PlanProblemCode(this.wire);

  final String wire;

  static PlanProblemCode? fromWire(String? v) => PlanProblemCode.values
      .firstWhereOrNull((PlanProblemCode c) => c.wire == v);

  /// Brání problém tomu, aby se dalo jet? `lockedConflict` ne — plán je
  /// platný, jenom se nepovedlo splnit všechno naráz.
  bool get isBlocking =>
      this == PlanProblemCode.noOutboundFound ||
      this == PlanProblemCode.noReturnFound ||
      this == PlanProblemCode.noDate ||
      this == PlanProblemCode.noDestination;
}

@immutable
class PlanProblem {
  const PlanProblem(this.code, {this.params = const <String, String>{}});

  final PlanProblemCode code;

  /// Parametry pro větu: `time`, `deadline`, `earliest`, `title`, `item`.
  /// Časy jsou v nich jako naivní ISO v zóně výletu, aby je prezentační
  /// vrstva nemusela znovu převádět.
  final Map<String, String> params;

  bool get isBlocking => code.isBlocking;

  Map<String, dynamic> toWire() => <String, dynamic>{
        'code': code.wire,
        'params': params,
      };

  static PlanProblem? fromWire(Object? v) {
    if (v is! Map) return null;
    final PlanProblemCode? code =
        PlanProblemCode.fromWire(v['code']?.toString());
    if (code == null) return null;
    final Object? p = v['params'];
    return PlanProblem(
      code,
      params: p is Map
          ? <String, String>{
              for (final MapEntry<Object?, Object?> e in p.entries)
                e.key.toString(): e.value?.toString() ?? '',
            }
          : const <String, String>{},
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlanProblem &&
      other.code == code &&
      mapEquals(other.params, params);

  @override
  int get hashCode => Object.hash(code, params.length);
}
