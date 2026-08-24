/// Celý plán výletu — časová osa plus zadání, ze kterého vznikla.
///
/// Constraints ([TripPlan.arriveBy], [TripPlan.homeBy]) jsou tu vedle položek
/// schválně. Nejsou to výsledky, jsou to zadání: „chci být doma do osmi" musí
/// přežít i přepočet, který to nesplnil — jinak by se příště hledalo podle
/// něčeho jiného, než co člověk řekl.
library;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'plan_item.dart';
import 'plan_problem.dart';

@immutable
class TripPlan {
  const TripPlan({
    required this.tripId,
    required this.items,
    this.id,
    this.variant = 'primary',
    this.planDate,
    this.departAfter,
    this.arriveBy,
    this.homeBy,
    this.provider,
    this.hasTimetable = false,
    this.revision = 0,
    this.timezone = 'Europe/Prague',
    this.warnings = const <PlanProblem>[],
  });

  /// Null, dokud plán nebyl ani jednou uložený.
  final String? id;
  final String tripId;
  final String variant;

  /// Den, na který plán je — naivní datum v zóně výletu.
  final DateTime? planDate;

  /// Nejdřív vyrazit v… Okamžik.
  final DateTime? departAfter;

  /// Být v cíli nejpozději v… Okamžik.
  final DateTime? arriveBy;

  /// Být doma nejpozději v… Okamžik.
  final DateTime? homeBy;

  final String? provider;

  /// False = časy jsou geometrický odhad, ne jízdní řád.
  final bool hasTimetable;

  /// Optimistický zámek proti souběžné úpravě z jiného telefonu.
  final int revision;
  final String timezone;

  /// Položky v chronologickém pořadí. Invariant, na který spoléhá celý
  /// replanning i vykreslení — udržuje ho [sorted].
  final List<PlanItem> items;

  final List<PlanProblem> warnings;

  bool get isEmpty => items.isEmpty;

  bool get hasBlockingProblem =>
      warnings.any((PlanProblem p) => p.isBlocking);

  /// Posun zóny výletu proti UTC, odvozený z položek.
  ///
  /// Server posílá okamžik i nástěnné hodiny; rozdíl mezi nimi je offset,
  /// který v ten den platí. Počítat ho z názvu zóny by znamenalo tahat do
  /// klienta tz databázi kvůli jednomu číslu, které už v datech je.
  Duration get zoneOffset {
    final PlanItem? first = items.firstOrNull;
    if (first == null) return Duration.zero;
    return PlanItem.offsetBetween(first.localStart, first.startsAt);
  }

  PlanItem? itemById(String id) =>
      items.firstWhereOrNull((PlanItem i) => i.id == id);

  List<PlanItem> segment(PlanSegment s) =>
      items.where((PlanItem i) => i.segment == s).toList();

  PlanItem? get lastOutbound => segment(PlanSegment.outbound).lastOrNull;
  PlanItem? get firstHomeward => segment(PlanSegment.homeward).firstOrNull;
  PlanItem? get lastHomeward => segment(PlanSegment.homeward).lastOrNull;

  /// Kdy skupina dorazí do cíle. Null, dokud není cesta tam.
  DateTime? get arrivalAtDestination => lastOutbound?.endsAt;

  /// Kdy vyráží zpátky.
  DateTime? get departureHome => firstHomeward?.startsAt;

  /// Kdy je skupina doma.
  DateTime? get arrivalHome => lastHomeward?.endsAt;

  DateTime? get startsAt => items.firstOrNull?.startsAt;
  DateTime? get endsAt => items.lastOrNull?.endsAt;

  /// Součet toho, co se dá sečíst. Vrací null, když se sčítat nedá nic —
  /// nula by tvrdila, že výlet je zadarmo.
  ({double min, double max})? get cost {
    final List<PlanItem> priced = items
        .where((PlanItem i) => i.costMin != null && i.costMax != null)
        .toList();
    if (priced.isEmpty) return null;
    return (
      min: priced.fold<double>(0, (double a, PlanItem i) => a + i.costMin!),
      max: priced.fold<double>(0, (double a, PlanItem i) => a + i.costMax!),
    );
  }

  TripPlan copyWith({
    String? id,
    DateTime? planDate,
    DateTime? departAfter,
    DateTime? arriveBy,
    DateTime? homeBy,
    String? provider,
    bool? hasTimetable,
    int? revision,
    String? timezone,
    List<PlanItem>? items,
    List<PlanProblem>? warnings,
    bool clearDepartAfter = false,
    bool clearArriveBy = false,
    bool clearHomeBy = false,
  }) =>
      TripPlan(
        id: id ?? this.id,
        tripId: tripId,
        variant: variant,
        planDate: planDate ?? this.planDate,
        departAfter: clearDepartAfter ? null : (departAfter ?? this.departAfter),
        arriveBy: clearArriveBy ? null : (arriveBy ?? this.arriveBy),
        homeBy: clearHomeBy ? null : (homeBy ?? this.homeBy),
        provider: provider ?? this.provider,
        hasTimetable: hasTimetable ?? this.hasTimetable,
        revision: revision ?? this.revision,
        timezone: timezone ?? this.timezone,
        items: items ?? this.items,
        warnings: warnings ?? this.warnings,
      );

  /// Kopie s položkami seřazenými chronologicky.
  ///
  /// Řadí se podle okamžiku, při shodě podle segmentu a pak podle ID. Bez
  /// druhého a třetího kritéria vrátí `sort` pro stejná data dvě různá
  /// pořadí a osa pod prstem přeskočí.
  TripPlan sorted() {
    final List<PlanItem> copy = <PlanItem>[...items]..sort((PlanItem a, PlanItem b) {
        final int t = a.startsAt.compareTo(b.startsAt);
        if (t != 0) return t;
        final int s = a.segment.index.compareTo(b.segment.index);
        if (s != 0) return s;
        return a.id.compareTo(b.id);
      });
    return copyWith(items: copy);
  }

  // --- drát ------------------------------------------------------------------

  static TripPlan fromWire(String tripId, Map<String, dynamic> r) {
    return TripPlan(
      id: r['id'] as String?,
      tripId: tripId,
      variant: (r['variant'] as String?) ?? 'primary',
      planDate: _date(r['plan_date'] as String?),
      departAfter: _instant(r['depart_after'] as String?),
      arriveBy: _instant(r['arrive_by'] as String?),
      homeBy: _instant(r['home_by'] as String?),
      provider: r['provider'] as String?,
      hasTimetable: (r['has_timetable'] as bool?) ?? false,
      revision: (r['revision'] as num?)?.toInt() ?? 0,
      timezone: (r['timezone'] as String?) ?? 'Europe/Prague',
      items: <PlanItem>[
        for (final Object? i
            in (r['items'] as List<dynamic>? ?? const <dynamic>[]))
          PlanItem.fromWire(i! as Map<String, dynamic>),
      ],
      warnings: _problems(r['warnings']),
    );
  }

  Map<String, dynamic> toWire() => <String, dynamic>{
        'variant': variant,
        'plan_date': planDate == null
            ? null
            : '${planDate!.year.toString().padLeft(4, '0')}-'
                '${planDate!.month.toString().padLeft(2, '0')}-'
                '${planDate!.day.toString().padLeft(2, '0')}',
        'depart_after': departAfter?.toUtc().toIso8601String(),
        'arrive_by': arriveBy?.toUtc().toIso8601String(),
        'home_by': homeBy?.toUtc().toIso8601String(),
        'provider': provider,
        'has_timetable': hasTimetable,
        'generated_by': 'engine-1',
        'warnings': <Map<String, dynamic>>[
          for (final PlanProblem w in warnings) w.toWire(),
        ],
        'items': <Map<String, dynamic>>[
          for (final PlanItem i in items) i.toWire(),
        ],
      };
}

List<PlanProblem> _problems(Object? v) {
  if (v is! List) return const <PlanProblem>[];
  final List<PlanProblem> out = <PlanProblem>[];
  for (final Object? e in v) {
    final PlanProblem? p = PlanProblem.fromWire(e);
    // Neznámý kód znamená, že server zná problém, o kterém tenhle build
    // nikdy neslyšel. Zahodit ho je lepší než spadnout na celé záložce.
    if (p != null) out.add(p);
  }
  return out;
}

DateTime? _instant(String? v) =>
    v == null || v.isEmpty ? null : DateTime.tryParse(v);

DateTime? _date(String? v) {
  if (v == null || v.isEmpty) return null;
  final DateTime? d = DateTime.tryParse(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}
