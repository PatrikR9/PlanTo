/// Cesta tam nebo zpět tak, jak ji čte člověk.
///
/// Na ose má každý pěší přechod a každý přestup vlastní řádek, protože každý
/// z nich je řádek v databázi. Na obrazovce je to ale šum: kdo se dívá, kdy
/// mu to jede, nepotřebuje bod „Přestup — Trutnov", potřebuje vidět, že v
/// Trutnově má šest minut. Tenhle soubor je ten překlad — z položek plánu na
/// řádky, které vypadají jako vyhledaný spoj.
///
/// Je to čistá funkce nad doménovým modelem schválně. Kdyby skládání bydlelo
/// ve widgetu, nešlo by otestovat, že přestup na stejné zastávce nevyrobí dva
/// řádky — a přesně to je věc, která se rozbije při první změně dat.
library;

import 'package:flutter/foundation.dart';

import 'plan_item.dart';

/// Jeden řádek cesty.
@immutable
sealed class TravelRow {
  const TravelRow();
}

/// Zastávka. Nese příjezd, odjezd, nebo obojí — přestup na místě je jeden
/// řádek se dvěma časy, ne dva řádky pod sebou.
@immutable
final class StopRow extends TravelRow {
  const StopRow({
    required this.name,
    this.arrival,
    this.departure,
    this.platform,
  });

  final String name;

  /// Naivní místní čas. Null u výchozí zastávky.
  final DateTime? arrival;

  /// Null u cílové zastávky.
  final DateTime? departure;

  final String? platform;

  StopRow _withDeparture(DateTime t, String? track) => StopRow(
        name: name,
        arrival: arrival,
        departure: t,
        platform: track ?? platform,
      );
}

/// Úsek jízdy. Nese celou položku, aby si obrazovka mohla vzít ikonu, linku
/// i zpoždění, aniž by se to sem muselo kopírovat.
@immutable
final class RideRow extends TravelRow {
  const RideRow(this.item);
  final PlanItem item;
}

/// Spojka mezi dvěma zastávkami — pěší přechod, čekání. Jenom text, žádný
/// bod: „pěšky 4 min" je poznámka na cestě, ne zastávka.
@immutable
final class LinkRow extends TravelRow {
  const LinkRow(this.text);
  final String text;
}

/// Celá cesta jedním směrem.
@immutable
class TravelOutline {
  const TravelOutline({
    required this.rows,
    required this.rides,
    required this.walkMinutes,
    this.localStart,
    this.localEnd,
    this.costMin,
    this.costMax,
    this.currency = 'CZK',
  });

  static const TravelOutline empty = TravelOutline(
    rows: <TravelRow>[],
    rides: 0,
    walkMinutes: 0,
  );

  final List<TravelRow> rows;

  /// Kolik úseků se jede. Přestupů je o jeden míň — a když se nejede nic,
  /// není to „cesta bez přestupu", je to prázdná cesta.
  final int rides;

  final int walkMinutes;

  final DateTime? localStart;
  final DateTime? localEnd;

  final double? costMin;
  final double? costMax;
  final String currency;

  bool get isEmpty => rows.isEmpty;

  int get transfers => rides <= 1 ? 0 : rides - 1;

  Duration? get duration => localStart == null || localEnd == null
      ? null
      : localEnd!.difference(localStart!);

  String? get fromName {
    for (final TravelRow r in rows) {
      if (r is StopRow) return r.name;
    }
    return null;
  }

  String? get toName {
    for (final TravelRow r in rows.reversed) {
      if (r is StopRow) return r.name;
    }
    return null;
  }
}

/// Poskládá řádky cesty z položek jednoho segmentu plánu.
///
/// Vstupem jsou položky jednoho segmentu v chronologickém pořadí. Aktivity a
/// jiné necestovní položky se ignorují — do cesty tam nepatří a kdyby se sem
/// dostaly, byla by to chyba jinde.
TravelOutline outlineFor(List<PlanItem> items) {
  if (items.isEmpty) return TravelOutline.empty;

  final List<TravelRow> rows = <TravelRow>[];
  int rides = 0;
  int walkMinutes = 0;
  double? costMin;
  double? costMax;
  String currency = 'CZK';

  // Rozepsané minuty, které se ještě nevypsaly jako spojka.
  int pendingWalk = 0;
  int pendingWait = 0;

  // Index poslední vypsané zastávky — kvůli doplnění odjezdu při přestupu.
  int? lastStopIndex;

  DateTime? firstTime;
  DateTime? lastTime;

  // Pěší úsek na konci cesty, který ještě nemá cílovou zastávku.
  PlanItem? tailWalk;

  void flushLink() {
    final List<String> parts = <String>[
      if (pendingWalk > 0) 'pěšky $pendingWalk min',
      if (pendingWait > 0) 'čekání $pendingWait min',
    ];
    if (parts.isNotEmpty) rows.add(LinkRow(parts.join(' · ')));
    pendingWalk = 0;
    pendingWait = 0;
  }

  for (final PlanItem item in items) {
    firstTime ??= item.localStart;
    lastTime = item.localEnd;

    switch (item.kind) {
      case PlanItemKind.transport:
        {
          final String? track = item.detail['platform'] as String?;
          final String from =
              _realName(item.fromName ?? item.titleParams['from']) ?? '';
          final String to =
              _realName(item.toName ?? item.titleParams['to']) ?? '';

          // Přestup na téže zastávce: doplní se odjezd do řádku, který tam
          // už je. Dva časy v jednom řádku jsou celý ten „naznač" — psát pod
          // to ještě „Přestup" by bylo totéž dvakrát.
          final int? at = lastStopIndex;
          final StopRow? last = at == null ? null : rows[at] as StopRow;

          // Chůze mezi nástupišti téže zastávky se nepočítá jako přechod
          // jinam: „Chlumec nad Cidlinou" dvakrát pod sebou vypadá jako chyba
          // v datech, i když to chyba není. Minuty zůstávají v součtu pěší
          // chůze, jen se z nich nestává řádek.
          if (at != null &&
              last != null &&
              last.name.isNotEmpty &&
              last.name == from) {
            rows[at] = last._withDeparture(item.localStart, track);
            pendingWait = 0;
            pendingWalk = 0;
          } else {
            flushLink();
            rows.add(
              StopRow(
                name: from,
                departure: item.localStart,
                platform: track,
              ),
            );
            lastStopIndex = rows.length - 1;
          }

          rows.add(RideRow(item));
          rows.add(StopRow(name: to, arrival: item.localEnd));
          lastStopIndex = rows.length - 1;
          rides++;
          tailWalk = null;

          if (item.costMin != null && item.costMax != null) {
            costMin = (costMin ?? 0) + item.costMin!;
            costMax = (costMax ?? 0) + item.costMax!;
            currency = item.currency;
          }
        }

      case PlanItemKind.walk:
        {
          walkMinutes += item.duration.inMinutes;
          pendingWalk += item.duration.inMinutes;

          // Odchod z domova: první řádek cesty je místo, odkud se vyráží.
          if (rows.isEmpty) {
            rows.add(
              StopRow(name: _walkFrom(item), departure: item.localStart),
            );
            lastStopIndex = rows.length - 1;
          }
          tailWalk = item;
        }

      case PlanItemKind.transfer:
        pendingWait += item.duration.inMinutes;

      case PlanItemKind.activity:
      case PlanItemKind.free:
      case PlanItemKind.meal:
      case PlanItemKind.accommodation:
      case PlanItemKind.custom:
        break;
    }
  }

  // Doběh: pěší úsek na konec, a za ním místo, kam se došlo.
  final PlanItem? tail = tailWalk;
  flushLink();
  if (tail != null) {
    rows.add(StopRow(name: _walkTo(tail), arrival: tail.localEnd));
  }

  return TravelOutline(
    rows: rows,
    rides: rides,
    walkMinutes: walkMinutes,
    localStart: firstTime,
    localEnd: lastTime,
    costMin: costMin,
    costMax: costMax,
    currency: currency,
  );
}

/// Odkud se jde. „Odchod z domova" nemá zastávku — je to výchozí bod, ne
/// místo v jízdním řádu, a nechat tam prázdno by rozbilo první řádek cesty.
String _walkFrom(PlanItem walk) {
  final String? named = _realName(walk.fromName ?? walk.titleParams['from']);
  if (named != null) return named;
  return walk.titleKey == 'plan.leave_home' ? 'Odchod z domova' : 'Start';
}

String _walkTo(PlanItem walk) {
  if (walk.titleKey == 'plan.walk_home') return 'Doma';
  return _realName(walk.toName ?? walk.titleParams['to']) ?? 'Cíl';
}

/// Vyhledávač pojmenovává krajní body trasy `START` a `END`, protože to
/// nejsou zastávky, ale souřadnice, které jsme mu poslali. Vypsat je na osu
/// znamená ukázat člověku vnitřní název cizí služby místo místa, odkud jede.
String? _realName(String? raw) {
  final String name = (raw ?? '').trim();
  if (name.isEmpty) return null;
  final String upper = name.toUpperCase();
  if (upper == 'START' || upper == 'END' || upper == 'VIA') return null;
  return name;
}
