import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../availability/data/availability_repository.dart';
import '../../../trips/domain/trip.dart';
import '../../domain/date_candidate.dart';

/// Dostupnost jako obrázek, ne jako seznam.
///
/// Seznam odpoví na „kdy můžeme", ale neodpoví na „kde je v tom týdnu díra".
/// Tvar volna se čte z plochy okamžitě a z osmnácti řádků textu nikdy — proto
/// tuhle mřížku má when2meet a proto ji lidé znají.
///
/// Data se neberou z nového dotazu. `trip_candidates` v časovém režimu vrací
/// **sloučené běhy**, které den beze zbytku pokrývají — každý slot patří právě
/// do jednoho z nich. Mřížka je tedy jen jejich vybarvení.
class AvailabilityGrid extends StatelessWidget {
  const AvailabilityGrid({
    required this.trip,
    required this.runs,
    required this.days,
    required this.onDayTap,
    this.selectedDay,
    super.key,
  });

  final Trip trip;

  /// Sloučené běhy z `trip_candidates`. V denním režimu se nepoužijí.
  final List<DateCandidate> runs;

  /// Dny okna. Určují sloupce i barvu v denním režimu.
  final List<DayAvailability> days;

  final void Function(DateTime day) onDayTap;
  final DateTime? selectedDay;

  static const double _cellW = 44;
  static const double _cellH = 13;
  static const double _gutter = 40;

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Barva podle podílu volných, v **pěti krocích**, ne plynule.
  ///
  /// Plynulá průhlednost vypadá na papíře elegantně a na obrazovce z ní byla
  /// jednolitá tyrkysová stěna: rozdíl mezi 4/5 a 5/5 je osm procent krytí,
  /// což lidské oko vedle sebe nerozezná. Skoková škála dělá z „chybí jeden
  /// člověk" viditelný předěl — a to je jediná informace, kvůli které se na
  /// mřížku někdo dívá.
  ///
  /// Plná shoda dostane navrch ještě sytější tón, protože to není další
  /// stupeň, to je odpověď.
  Color _shade(BuildContext context, double? ratio) {
    if (ratio == null) return context.colors.surfaceContainerHighest;
    if (ratio <= 0) return context.colors.surfaceContainerHigh;
    if (ratio >= 1) return context.planto.availabilityFull;

    const List<double> steps = <double>[0.18, 0.34, 0.50, 0.66];
    final int i = (ratio * steps.length).ceil().clamp(1, steps.length) - 1;
    return context.planto.availabilityPartial.withValues(alpha: steps[i]);
  }

  /// Vysvětlivka. Bez ní je barevná plocha hezká a nečitelná — nikdo neví,
  /// jestli je tmavší lepší, nebo horší.
  Widget _legend(BuildContext context) {
    Widget swatch(Color c) => Container(
          width: 14,
          height: 14,
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: context.planto.hairline),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.md, 0, Sp.md, Sp.xs),
      child: Row(
        children: <Widget>[
          Text(
            'nikdo',
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(width: Sp.xxs),
          swatch(_shade(context, 0)),
          swatch(_shade(context, 0.25)),
          swatch(_shade(context, 0.5)),
          swatch(_shade(context, 0.75)),
          swatch(_shade(context, 1)),
          const SizedBox(width: Sp.xxs),
          Text(
            'všichni',
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const Spacer(),
          Text(
            // Řečeno přímo v místě, kde vzniká záměna: u vícedenního pobytu
            // je číslo v buňce jiná veličina než číslo na kartě.
            !trip.isTimed && trip.durationDays > 1
                ? 'buňka = jeden den, ne celý pobyt'
                : 'klepnutím vyberete den',
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _legend(context),
        if (trip.isTimed) _timed(context) else _byDay(context),
      ],
    );
  }

  // ------------------------------------------------------------ časový --

  Widget _timed(BuildContext context) {
    final int stepMin = trip.slotStepMinutes;
    final int spanMin =
        (trip.dayEnd - trip.dayStart - trip.slotDuration).inMinutes;
    // Aktivita se do dne nevejde ani jednou.
    if (spanMin < 0 || stepMin <= 0) return const SizedBox.shrink();
    final int rows = spanMin ~/ stepMin + 1;

    // Běhy podle dne, ať se pro každou buňku neprochází celý seznam.
    final Map<String, List<DateCandidate>> byDay =
        <String, List<DateCandidate>>{};
    for (final DateCandidate r in runs) {
      byDay.putIfAbsent(_key(r.day), () => <DateCandidate>[]).add(r);
    }

    final DateFormat dayFmt = DateFormat('E', 'cs');
    final DateFormat numFmt = DateFormat('d.M.', 'cs');

    const double headH = 38;
    final double bodyH = rows * _cellH;
    // Strop výšky. Mřížka je přehled, ne celá obrazovka — čtrnáct hodin při
    // kroku 30 minut je 28 řádků a ty se pod pruh se seznamem nevejdou.
    // Bez tohohle přetekla o 256 pixelů a Flutter přes ni nakreslil ten
    // žlutočerný pruh.
    final double viewH = (headH + bodyH) < 320 ? headH + bodyH : 320;

    return SizedBox(
      height: viewH,
      child: SingleChildScrollView(
        child: SizedBox(
          height: headH + bodyH,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: _gutter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    const SizedBox(height: headH),
                    for (int r = 0; r < rows; r++)
                      SizedBox(
                        height: _cellH,
                        child: _isFullHour(r, stepMin)
                            ? Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Text(
                                  _timeLabel(r, stepMin),
                                  style: context.texts.labelSmall?.copyWith(
                                    color: context.colors.onSurfaceVariant,
                                    height: 1,
                                  ),
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(right: Sp.md),
                  itemCount: days.length,
                  itemBuilder: (BuildContext context, int i) {
                    final DayAvailability d = days[i];
                    final List<DateCandidate> dayRuns =
                        byDay[_key(d.day)] ?? const <DateCandidate>[];
                    final bool sel =
                        selectedDay != null && _sameDay(selectedDay!, d.day);

                    return GestureDetector(
                      onTap: () => onDayTap(d.day),
                      child: Container(
                        width: _cellW,
                        margin: const EdgeInsets.only(right: 3),
                        decoration: BoxDecoration(
                          borderRadius: Radii.inputAll,
                          border: Border.all(
                            color: sel
                                ? context.colors.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: Column(
                          children: <Widget>[
                            SizedBox(
                              height: headH,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: <Widget>[
                                  Text(
                                    dayFmt.format(d.day),
                                    style: context.texts.labelSmall?.copyWith(
                                      height: 1,
                                      color: d.isWeekend || d.isHoliday
                                          ? context.colors.primary
                                          : context.colors.onSurfaceVariant,
                                    ),
                                  ),
                                  Text(
                                    numFmt.format(d.day),
                                    style: context.texts.labelSmall?.copyWith(
                                      height: 1.3,
                                      fontWeight: sel
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            for (int r = 0; r < rows; r++)
                              _Cell(
                                color: _shade(
                                  context,
                                  _ratioAt(dayRuns, d.day, r, stepMin),
                                ),
                                hourLine: _isFullHour(r, stepMin),
                                top: r == 0,
                                bottom: r == rows - 1,
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _key(DateTime d) => '${d.year}-${d.month}-${d.day}';

  static bool _isFullHour(int row, int stepMin) => (row * stepMin) % 60 == 0;

  String _timeLabel(int row, int stepMin) {
    final Duration t = trip.dayStart + Duration(minutes: row * stepMin);
    return '${t.inHours}:00';
  }

  /// Podíl volných v buňce, nebo null když ji nekryje žádný běh.
  double? _ratioAt(
    List<DateCandidate> dayRuns,
    DateTime day,
    int row,
    int stepMin,
  ) {
    final DateTime start = DateTime(day.year, day.month, day.day)
        .add(trip.dayStart + Duration(minutes: row * stepMin));
    for (final DateCandidate r in dayRuns) {
      // Místní čas výletu na obou stranách: `start` se skládá z day_start,
      // což je také čas výletu. Porovnávat ho s UTC okamžikem by mřížku
      // posunulo o offset zóny.
      if (!start.isBefore(r.localStart) && start.isBefore(r.localWindowEnd)) {
        return r.totalCount == 0 ? null : r.freeCount / r.totalCount;
      }
    }
    return null;
  }

  // -------------------------------------------------------------- denní --

  /// Vícedenní výlet nemá časovou osu, takže mřížka je kalendář.
  ///
  /// Týden na řádek, protože „vyjde nám to o víkendu" je otázka, kterou si
  /// skupina klade první — a v jednom dlouhém pásu se sobota od středy
  /// nepozná.
  Widget _byDay(BuildContext context) {
    final DateTime first = days.first.day;
    // Pondělí = 1. Odsazení, aby sloupce odpovídaly dnům v týdnu.
    final int lead = first.weekday - 1;
    final List<DayAvailability?> cells = <DayAvailability?>[
      ...List<DayAvailability?>.filled(lead, null),
      ...days,
    ];

    const List<String> heads = <String>[
      'po',
      'út',
      'st',
      'čt',
      'pá',
      'so',
      'ne',
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.md),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              for (int i = 0; i < 7; i++)
                Expanded(
                  child: Text(
                    heads[i],
                    textAlign: TextAlign.center,
                    style: context.texts.labelSmall?.copyWith(
                      color: i >= 5
                          ? context.colors.primary
                          : context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Sp.xxs),
          for (int rowStart = 0; rowStart < cells.length; rowStart += 7)
            Row(
              children: <Widget>[
                for (int i = 0; i < 7; i++)
                  Expanded(
                    child: _DayCell(
                      day: rowStart + i < cells.length
                          ? cells[rowStart + i]
                          : null,
                      selected: rowStart + i < cells.length &&
                          cells[rowStart + i] != null &&
                          selectedDay != null &&
                          _sameDay(selectedDay!, cells[rowStart + i]!.day),
                      shade: (double? r) => _shade(context, r),
                      onTap: onDayTap,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.color,
    required this.hourLine,
    required this.top,
    required this.bottom,
  });

  final Color color;

  /// Celá hodina. Linka jen tam, ne kolem každé buňky: mřížka se čte podle
  /// hodin, a čára po půlhodinách z ní dělá šrafuru.
  final bool hourLine;

  final bool top;
  final bool bottom;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AvailabilityGrid._cellH,
      decoration: BoxDecoration(
        color: color,
        border: Border(
          top: BorderSide(
            color:
                hourLine || top ? context.planto.hairline : Colors.transparent,
            width: hourLine || top ? 1 : 0,
          ),
          bottom: BorderSide(
            color: bottom ? context.planto.hairline : Colors.transparent,
            width: bottom ? 1 : 0,
          ),
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.selected,
    required this.shade,
    required this.onTap,
  });

  final DayAvailability? day;
  final bool selected;
  final Color Function(double? ratio) shade;
  final void Function(DateTime day) onTap;

  @override
  Widget build(BuildContext context) {
    final DayAvailability? d = day;
    if (d == null) return const SizedBox(height: 48);

    return Padding(
      padding: const EdgeInsets.all(1),
      child: InkWell(
        onTap: () => onTap(d.day),
        borderRadius: Radii.inputAll,
        child: Container(
          height: 46,
          decoration: BoxDecoration(
            color: shade(d.ratio),
            borderRadius: Radii.inputAll,
            border: Border.all(
              color:
                  selected ? context.colors.primary : context.planto.hairline,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text('${d.day.day}.', style: context.texts.labelLarge),
              Text(
                '${d.freeCount}/${d.totalCount}',
                style: context.texts.labelSmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
