/// Jedna položka časové osy výletu.
///
/// Osa není seznam widgetů. Každý řádek, který na ní uživatel vidí, je řádek
/// v `itinerary_items` — má ID, druh, časy, zdroj a stav zámku. Bez toho by
/// po zavření a otevření výletu zbyl jenom seznam časů a engine by neměl jak
/// poznat, co si člověk vybral sám a co smí přepočítat.
library;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

/// Co se v tu dobu děje.
///
/// `wire` je kontrakt s enumem `plan_item_kind` v databázi. Serializace přes
/// `.name` je jedno přejmenování od tiché ztráty dat.
enum PlanItemKind {
  transport('transport'),
  walk('walk'),
  transfer('transfer'),
  activity('activity'),
  free('free'),
  meal('meal'),
  accommodation('accommodation'),
  custom('custom');

  const PlanItemKind(this.wire);

  final String wire;

  static PlanItemKind fromWire(String? v) =>
      PlanItemKind.values.firstWhereOrNull((PlanItemKind k) => k.wire == v) ??
      PlanItemKind.custom;

  /// Úseky cesty. Ty engine nahrazuje celé; aktivitu jenom posouvá.
  bool get isTravel =>
      this == PlanItemKind.transport ||
      this == PlanItemKind.walk ||
      this == PlanItemKind.transfer;
}

/// Odkud položka je. Tohle rozhoduje, co smí replanning přepsat.
enum PlanItemSource {
  /// Vyrobil engine. Smí se přepočítat bez ptaní.
  generated('generated'),

  /// Konkrétní spoj z vyhledávače, vybraný automaticky. Smí se vyměnit.
  provider('provider'),

  /// Spoj, který si vybral člověk. Vyměnit jen s upozorněním — jinak by
  /// aplikace tiše přepsala rozhodnutí, kvůli kterému si někdo otevřel
  /// seznam spojů.
  userSelected('user_selected'),

  /// Položka, kterou člověk založil. Engine ji nemaže ani nenahrazuje.
  userCreated('user_created');

  const PlanItemSource(this.wire);

  final String wire;

  static PlanItemSource fromWire(String? v) =>
      PlanItemSource.values
          .firstWhereOrNull((PlanItemSource s) => s.wire == v) ??
      PlanItemSource.generated;
}

/// Která část výletu. Tohle dělá z „přepočítej jenom cestu zpět" levnou
/// operaci místo prohledávání celého plánu.
enum PlanSegment {
  outbound('outbound'),
  stay('stay'),

  /// `return` je v Dartu klíčové slovo, takže `homeward`. Na drátě je
  /// pořád 'return', protože tak se jmenuje hodnota v databázi.
  homeward('return');

  const PlanSegment(this.wire);

  final String wire;

  static PlanSegment fromWire(String? v) =>
      PlanSegment.values.firstWhereOrNull((PlanSegment s) => s.wire == v) ??
      PlanSegment.stay;
}

/// Nakolik se dá věřit času a ceně u téhle položky.
enum PlanConfidence {
  /// Z důvěryhodného zdroje jako přesná hodnota. U jízdného v ČR to zatím
  /// neumí nikdo, takže se tahle hodnota u dopravy neobjeví.
  exact('exact'),
  estimated('estimated'),
  rough('rough');

  const PlanConfidence(this.wire);

  final String wire;

  static PlanConfidence fromWire(String? v) =>
      PlanConfidence.values
          .firstWhereOrNull((PlanConfidence c) => c.wire == v) ??
      PlanConfidence.estimated;
}

/// Lokální ID pro položku, která ještě nebyla uložená.
///
/// Balíček na UUID by kvůli tomuhle byl zbytečná závislost: ID přiděluje
/// `save_trip_plan()` a klient potřebuje jenom něco, čím položku odliší ve
/// vlastním stavu do prvního uložení. Prefix je součást kontraktu —
/// [PlanItem.isNew] se podle něj pozná a na drát pošle null.
int _newSeq = 0;
String newPlanItemId() => 'new-${_newSeq++}';

@immutable
class PlanItem {
  const PlanItem({
    required this.id,
    required this.kind,
    required this.segment,
    required this.startsAt,
    required this.endsAt,
    required this.localStart,
    required this.localEnd,
    required this.titleKey,
    this.titleParams = const <String, String>{},
    this.detail = const <String, dynamic>{},
    this.fromName,
    this.toName,
    this.placeId,
    this.costMin,
    this.costMax,
    this.currency = 'CZK',
    this.confidence = PlanConfidence.estimated,
    this.source = PlanItemSource.generated,
    this.isLocked = false,
    this.userEdited = false,
  });

  final String id;
  final PlanItemKind kind;
  final PlanSegment segment;

  /// Okamžiky. S nimi se počítá a řadí.
  final DateTime startsAt;
  final DateTime endsAt;

  /// Nástěnné hodiny v zóně výletu. Ty se ukazují a ty uživatel edituje.
  final DateTime localStart;
  final DateTime localEnd;

  /// Klíč a parametry, ne hotová věta. Čeština potřebuje ICU a věta ve
  /// sloupci se nedá přeskloňovat ani přeložit (architektura §9.5).
  final String titleKey;
  final Map<String, String> titleParams;

  /// Náš model spoje u dopravy, poznámka u aktivity. Nikdy odpověď
  /// poskytovatele.
  final Map<String, dynamic> detail;

  final String? fromName;
  final String? toName;
  final String? placeId;

  final double? costMin;
  final double? costMax;
  final String currency;
  final PlanConfidence confidence;

  final PlanItemSource source;

  /// Engine tuhle položku nesmí posunout ani vyměnit.
  final bool isLocked;

  /// Uživatel s ní už jednou hnul rukou. Slabší než [isLocked]: engine ji
  /// posune, jen když jinak nemá řešení — a řekne to.
  final bool userEdited;

  Duration get duration => endsAt.difference(startsAt);
  bool get isFlexible => !isLocked;

  /// Nová položka, kterou server ještě nezná.
  bool get isNew => id.startsWith('new-');

  /// Smí ji uživatel smazat? Úsek cesty ne — ten zmizí s přepočtem trasy,
  /// ne tlačítkem, protože bez něj by v ose zůstala díra a plán by tvrdil,
  /// že se skupina teleportuje.
  bool get canDelete => !kind.isTravel;

  /// Smí uživatel měnit délku? U jízdy ne: délku jízdy určuje jízdní řád.
  bool get canResize =>
      kind == PlanItemKind.activity ||
      kind == PlanItemKind.free ||
      kind == PlanItemKind.meal ||
      kind == PlanItemKind.accommodation ||
      kind == PlanItemKind.custom;

  /// Vybral si tenhle spoj člověk?
  bool get isUserChoice =>
      source == PlanItemSource.userSelected ||
      source == PlanItemSource.userCreated;

  PlanItem copyWith({
    PlanItemKind? kind,
    PlanSegment? segment,
    DateTime? startsAt,
    DateTime? endsAt,
    DateTime? localStart,
    DateTime? localEnd,
    String? titleKey,
    Map<String, String>? titleParams,
    Map<String, dynamic>? detail,
    String? fromName,
    String? toName,
    String? placeId,
    double? costMin,
    double? costMax,
    String? currency,
    PlanConfidence? confidence,
    PlanItemSource? source,
    bool? isLocked,
    bool? userEdited,
  }) =>
      PlanItem(
        id: id,
        kind: kind ?? this.kind,
        segment: segment ?? this.segment,
        startsAt: startsAt ?? this.startsAt,
        endsAt: endsAt ?? this.endsAt,
        localStart: localStart ?? this.localStart,
        localEnd: localEnd ?? this.localEnd,
        titleKey: titleKey ?? this.titleKey,
        titleParams: titleParams ?? this.titleParams,
        detail: detail ?? this.detail,
        fromName: fromName ?? this.fromName,
        toName: toName ?? this.toName,
        placeId: placeId ?? this.placeId,
        costMin: costMin ?? this.costMin,
        costMax: costMax ?? this.costMax,
        currency: currency ?? this.currency,
        confidence: confidence ?? this.confidence,
        source: source ?? this.source,
        isLocked: isLocked ?? this.isLocked,
        userEdited: userEdited ?? this.userEdited,
      );

  /// Posun o pevný interval. Posouvá okamžik i nástěnné hodiny současně —
  /// jinak by se ty dvě reprezentace téhož času rozešly.
  ///
  /// Přes přechod letního času to o hodinu ujede. Je to vědomý ústupek:
  /// server posílá místní časy autoritativně při každém načtení, takže
  /// nesrovnalost žije do prvního uložení. Alternativa je tz databáze
  /// v klientovi, což je 900 kB kvůli jednomu dni v roce.
  PlanItem shiftedBy(Duration d) => copyWith(
        startsAt: startsAt.add(d),
        endsAt: endsAt.add(d),
        localStart: localStart.add(d),
        localEnd: localEnd.add(d),
      );

  /// Nový začátek při zachované délce.
  PlanItem movedTo(DateTime newStart) => shiftedBy(newStart.difference(startsAt));

  /// Nový začátek zadaný v místním čase. Uživatel vybírá „v deset", ne
  /// okamžik, a posun se musí počítat proti té samé reprezentaci.
  PlanItem movedToLocal(DateTime wallClock) =>
      shiftedBy(wallClock.difference(localStart));

  /// Nová délka při zachovaném začátku.
  PlanItem resizedTo(Duration d) => copyWith(
        endsAt: startsAt.add(d),
        localEnd: localStart.add(d),
      );

  // --- převod z/na zónu ------------------------------------------------------

  /// Okamžik z nástěnných hodin. [zoneOffset] je posun zóny výletu proti UTC.
  static DateTime instantOf(DateTime wallClock, Duration zoneOffset) =>
      DateTime.utc(
        wallClock.year,
        wallClock.month,
        wallClock.day,
        wallClock.hour,
        wallClock.minute,
        wallClock.second,
      ).subtract(zoneOffset);

  /// Posun zóny výletu proti UTC, odvozený z dvojice (nástěnné hodiny,
  /// okamžik). Server posílá obojí, takže offset už v datech je — počítat ho
  /// z názvu zóny by znamenalo tahat do klienta tz databázi kvůli jednomu
  /// číslu.
  static Duration offsetBetween(DateTime wallClock, DateTime instant) =>
      DateTime.utc(
        wallClock.year,
        wallClock.month,
        wallClock.day,
        wallClock.hour,
        wallClock.minute,
        wallClock.second,
      ).difference(instant.toUtc());

  /// Nástěnné hodiny z okamžiku.
  static DateTime wallClockOf(DateTime instant, Duration zoneOffset) {
    final DateTime u = instant.toUtc().add(zoneOffset);
    return DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second);
  }

  /// Položka zadaná v místním čase. Používá to builder i editace uživatelem —
  /// obojí přemýšlí v „v deset", ne v okamžicích.
  static PlanItem atLocal({
    required String id,
    required PlanItemKind kind,
    required PlanSegment segment,
    required DateTime localStart,
    required DateTime localEnd,
    required Duration zoneOffset,
    required String titleKey,
    Map<String, String> titleParams = const <String, String>{},
    Map<String, dynamic> detail = const <String, dynamic>{},
    String? fromName,
    String? toName,
    String? placeId,
    double? costMin,
    double? costMax,
    String currency = 'CZK',
    PlanConfidence confidence = PlanConfidence.estimated,
    PlanItemSource source = PlanItemSource.generated,
    bool isLocked = false,
    bool userEdited = false,
  }) =>
      PlanItem(
        id: id,
        kind: kind,
        segment: segment,
        startsAt: instantOf(localStart, zoneOffset),
        endsAt: instantOf(localEnd, zoneOffset),
        localStart: localStart,
        localEnd: localEnd,
        titleKey: titleKey,
        titleParams: titleParams,
        detail: detail,
        fromName: fromName,
        toName: toName,
        placeId: placeId,
        costMin: costMin,
        costMax: costMax,
        currency: currency,
        confidence: confidence,
        source: source,
        isLocked: isLocked,
        userEdited: userEdited,
      );

  // --- drát ------------------------------------------------------------------

  static PlanItem fromWire(Map<String, dynamic> r) {
    final DateTime start = DateTime.parse(r['starts_at'] as String);
    final DateTime end = DateTime.parse(r['ends_at'] as String);
    return PlanItem(
      id: r['id'] as String,
      kind: PlanItemKind.fromWire(r['kind'] as String?),
      segment: PlanSegment.fromWire(r['segment'] as String?),
      startsAt: start,
      endsAt: end,
      localStart: _localOr(r['local_starts_at'] as String?, start),
      localEnd: _localOr(r['local_ends_at'] as String?, end),
      titleKey: (r['title_key'] as String?) ?? 'plan.item',
      titleParams: _stringMap(r['title_params']),
      detail: (r['detail'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      fromName: r['from_name'] as String?,
      toName: r['to_name'] as String?,
      placeId: r['place_id'] as String?,
      costMin: (r['cost_min'] as num?)?.toDouble(),
      costMax: (r['cost_max'] as num?)?.toDouble(),
      currency: (r['currency'] as String?) ?? 'CZK',
      confidence: PlanConfidence.fromWire(r['confidence'] as String?),
      source: PlanItemSource.fromWire(r['source'] as String?),
      isLocked: (r['is_locked'] as bool?) ?? false,
      userEdited: (r['user_edited'] as bool?) ?? false,
    );
  }

  /// Místní časy se neposílají — počítá je server ze zóny výletu. Kdyby je
  /// posílal klient, měl by plán dvě pravdy o tom, kdy se jede.
  Map<String, dynamic> toWire() => <String, dynamic>{
        'id': isNew ? null : id,
        'kind': kind.wire,
        'segment': segment.wire,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'ends_at': endsAt.toUtc().toIso8601String(),
        'title_key': titleKey,
        'title_params': titleParams,
        'detail': detail,
        'from_name': fromName,
        'to_name': toName,
        'place_id': placeId,
        'cost_min': costMin,
        'cost_max': costMax,
        'currency': currency,
        'confidence': confidence.wire,
        'source': source.wire,
        'is_locked': isLocked,
        'user_edited': userEdited,
      };

  @override
  bool operator ==(Object other) => other is PlanItem && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

DateTime _localOr(String? local, DateTime instant) {
  if (local != null && local.isNotEmpty) {
    final DateTime? parsed = DateTime.tryParse(local);
    if (parsed != null && !parsed.isUtc) return parsed;
  }
  final DateTime l = instant.toLocal();
  return DateTime(l.year, l.month, l.day, l.hour, l.minute, l.second);
}

Map<String, String> _stringMap(Object? v) {
  if (v is! Map) return const <String, String>{};
  return <String, String>{
    for (final MapEntry<Object?, Object?> e in v.entries)
      e.key.toString(): e.value?.toString() ?? '',
  };
}
