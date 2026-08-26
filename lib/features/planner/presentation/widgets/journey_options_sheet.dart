import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/format/cs_format.dart';
import '../../domain/journey.dart';
import '../plan_strings.dart';
import 'time_picking.dart';

/// Vyhledání spoje — jeden dotaz na poskytovatele.
///
/// [whenLocal] jsou nástěnné hodiny v zóně výletu, [arriveBy] říká, jestli se
/// ten čas vztahuje k odjezdu, nebo k příjezdu.
typedef JourneyLookup = Future<JourneySearch> Function(
  DateTime whenLocal, {
  required bool arriveBy,
});

/// Vyhledávač spojení, postavený jako v IDOS.
///
/// Nahoře zadání — přepínač **Odjezd / Příjezd**, datum a čas —, pod ním
/// výsledky a šipky na dřívější a pozdější spoje. Je to schválně tvar, který
/// každý v Česku zná: kdo hledá spoj, hledá ho odjinud pětkrát týdně a
/// vymýšlet mu na to vlastní ovládání znamená učit ho něco, co už umí.
///
/// Dokud se nevybere spoj, plán se nemění. To je ten rozdíl proti dřívější
/// verzi, kde každé klepnutí rovnou přepočítávalo plán a nebylo poznat, co
/// je zadání a co výsledek.
Future<Journey?> showJourneySheet(
  BuildContext context, {
  required String title,
  required JourneyLookup lookup,
  required DateTime initialWhen,
  bool initialArriveBy = false,
  DateTime? firstDay,
  DateTime? lastDay,
}) {
  return showModalBottomSheet<Journey>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
    builder: (BuildContext context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      builder: (BuildContext context, ScrollController controller) =>
          _JourneySearchSheet(
        title: title,
        lookup: lookup,
        initialWhen: initialWhen,
        initialArriveBy: initialArriveBy,
        firstDay: firstDay,
        lastDay: lastDay,
        controller: controller,
      ),
    ),
  );
}

class _JourneySearchSheet extends StatefulWidget {
  const _JourneySearchSheet({
    required this.title,
    required this.lookup,
    required this.initialWhen,
    required this.initialArriveBy,
    required this.controller,
    this.firstDay,
    this.lastDay,
  });

  final String title;
  final JourneyLookup lookup;
  final DateTime initialWhen;
  final bool initialArriveBy;
  final ScrollController controller;
  final DateTime? firstDay;
  final DateTime? lastDay;

  @override
  State<_JourneySearchSheet> createState() => _JourneySearchSheetState();
}

class _JourneySearchSheetState extends State<_JourneySearchSheet> {
  late DateTime _when = widget.initialWhen;
  late bool _arriveBy = widget.initialArriveBy;

  /// Všechno, co se zatím našlo, seřazené podle odjezdu.
  List<Journey> _found = const <Journey>[];

  /// Začíná se načítáním: první hledání se pouští hned po prvním snímku a
  /// „Žádný spoj" na jednu obrátku vypadá jako odpověď, kterou to není.
  bool _loading = true;
  bool _exhausted = false;
  Object? _error;
  String? _attribution;
  bool _hasTimetable = true;

  /// Kolikátý dotaz běží. Odpověď na starší dotaz se zahodí — jinak by
  /// pomalejší hledání přepsalo výsledky toho, na co se člověk ptal potom.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
    // Po prvním snímku, ne hned: `setState` v `initState` je chyba a první
    // hledání jednou `setState` volá, protože zapíná načítání.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _restart());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  /// Donačítání místo tlačítka „Pozdější". Práh je 600 px, ne úplný konec:
  /// seznam se má natáhnout dřív, než na něj člověk dojede.
  void _onScroll() {
    if (_loading || _exhausted || _found.isEmpty) return;
    if (!widget.controller.hasClients) return;
    final ScrollPosition p = widget.controller.position;
    if (p.pixels >= p.maxScrollExtent - 600) _loadMore();
  }

  Future<void> _restart() async {
    setState(() {
      _found = const <Journey>[];
      _exhausted = false;
      _error = null;
    });
    await _load(_when, arriveBy: _arriveBy);
  }

  Future<void> _loadMore() {
    // Další stránka jsou odjezdy po tom posledním, který už je v seznamu.
    final DateTime from =
        _found.last.localDeparture.add(const Duration(minutes: 1));
    return _load(from, arriveBy: false);
  }

  Future<void> _load(DateTime when, {required bool arriveBy}) async {
    final int mine = ++_generation;
    setState(() => _loading = true);
    try {
      final JourneySearch r = await widget.lookup(when, arriveBy: arriveBy);
      if (!mounted || mine != _generation) return;
      final List<Journey> merged = _merge(_found, r.journeys);
      setState(() {
        _loading = false;
        _error = null;
        _attribution = r.attribution ?? _attribution;
        _hasTimetable = r.hasTimetable;
        // Nic nového = dál už nic není. Bez tohohle by donačítání jelo
        // donekonečna a pořád se ptalo komunitní služby na totéž.
        _exhausted = merged.length == _found.length;
        _found = merged;
      });
    } on Object catch (e) {
      if (!mounted || mine != _generation) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  void _search() {
    setState(() => _exhausted = false);
    _restart();
  }

  Future<void> _pickDate() async {
    final DateTime first = widget.firstDay ?? _when;
    final DateTime last = widget.lastDay ?? _when;
    final DateTime day = DateTime(_when.year, _when.month, _when.day);
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate:
          day.isBefore(first) ? first : (day.isAfter(last) ? last : day),
      firstDate: first,
      lastDate: last.isBefore(first) ? first : last,
      helpText: 'Který den?',
    );
    if (picked == null) return;
    _when = DateTime(
      picked.year,
      picked.month,
      picked.day,
      _when.hour,
      _when.minute,
    );
    await _restart();
  }

  Future<void> _pickTime() async {
    final DateTime? picked = await pickLocalTime(context, _when);
    if (picked == null) return;
    _when = picked;
    await _restart();
  }

  @override
  Widget build(BuildContext context) {
    final bool oneDay = widget.firstDay == null ||
        widget.lastDay == null ||
        (widget.firstDay!.year == widget.lastDay!.year &&
            widget.firstDay!.month == widget.lastDay!.month &&
            widget.firstDay!.day == widget.lastDay!.day);

    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(Sp.lg, 0, Sp.lg, Sp.xl),
      children: <Widget>[
        Text(widget.title, style: context.texts.titleMedium),
        const SizedBox(height: Sp.sm),

        // --- zadání ---------------------------------------------------------
        SegmentedButton<bool>(
          segments: const <ButtonSegment<bool>>[
            ButtonSegment<bool>(value: false, label: Text('Odjezd')),
            ButtonSegment<bool>(value: true, label: Text('Příjezd')),
          ],
          selected: <bool>{_arriveBy},
          showSelectedIcon: false,
          onSelectionChanged: (Set<bool> s) {
            _arriveBy = s.first;
            _restart();
          },
        ),
        const SizedBox(height: Sp.xs),
        Row(
          children: <Widget>[
            if (!oneDay) ...<Widget>[
              Expanded(
                child: PtButton(
                  label: DateFormat('E d. M.', 'cs').format(_when),
                  variant: PtButtonVariant.tonal,
                  icon: Icons.event,
                  expand: true,
                  onPressed: _pickDate,
                ),
              ),
              const SizedBox(width: Sp.xs),
            ],
            Expanded(
              child: PtButton(
                label: formatClock(_when),
                variant: PtButtonVariant.tonal,
                icon: Icons.schedule,
                expand: true,
                onPressed: _pickTime,
              ),
            ),
            const SizedBox(width: Sp.xs),
            PtButton(
              label: 'Hledat',
              icon: Icons.search,
              onPressed: _search,
            ),
          ],
        ),
        const SizedBox(height: Sp.md),

        if (!_hasTimetable && _found.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.xs),
            child: Text(
              'Bez jízdního řádu — časy jsou odhad ze vzdálenosti.',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.error),
            ),
          ),

        for (final Journey j in _found) ...<Widget>[
          _JourneyCard(
            journey: j,
            onTap: () => Navigator.of(context).pop(j),
          ),
          const SizedBox(height: Sp.xs),
        ],

        _Footer(
          loading: _loading,
          error: _error,
          empty: _found.isEmpty,
          exhausted: _exhausted,
          onRetry: _search,
        ),

        if (_attribution case final String a)
          Padding(
            padding: const EdgeInsets.only(top: Sp.sm),
            child: Text(
              a,
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

/// Sloučí novou stránku do toho, co už je na obrazovce.
///
/// Řadí se podle odjezdu a při shodném odjezdu zůstane ten rychlejší.
/// Vyhledávač vrací i varianty, které vyjíždějí ve stejnou minutu a liší se
/// jen tím, že jedna z nich někde přečká noc — a dvě karty se stejným časem,
/// kde jedna dojede „po 16:52", vypadají jako chyba v datech.
List<Journey> _merge(List<Journey> current, List<Journey> incoming) {
  final Map<String, Journey> byId = <String, Journey>{
    for (final Journey j in current) j.id: j,
    for (final Journey j in incoming) j.id: j,
  };

  final Map<String, Journey> byDeparture = <String, Journey>{};
  for (final Journey j in byId.values) {
    final String key = j.localDeparture.toIso8601String();
    final Journey? seen = byDeparture[key];
    if (seen == null || j.durationMinutes < seen.durationMinutes) {
      byDeparture[key] = j;
    }
  }

  final List<Journey> out = byDeparture.values.toList()
    ..sort((Journey a, Journey b) {
      final int t = a.localDeparture.compareTo(b.localDeparture);
      return t != 0 ? t : a.durationMinutes.compareTo(b.durationMinutes);
    });
  return out;
}

/// Patička seznamu: načítání, chyba, prázdno, konec.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.loading,
    required this.error,
    required this.empty,
    required this.exhausted,
    required this.onRetry,
  });

  final bool loading;
  final Object? error;
  final bool empty;
  final bool exhausted;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (error case final Object e) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.md),
        child: PtErrorState(message: errorText(e), onRetry: onRetry),
      );
    }
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Sp.md),
        child: Column(
          children: <Widget>[
            PtSkeleton(height: 84),
            SizedBox(height: Sp.xs),
            PtSkeleton(height: 84),
          ],
        ),
      );
    }
    if (empty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Sp.md),
        child: PtEmptyState(
          title: 'Žádný spoj',
          // Nikdy nepředstírat, že trasa existuje. Prázdný výsledek je
          // odpověď, ne chyba k obejití.
          message: 'Pro tenhle čas vyhledávač nenašel žádné spojení. '
              'Zkuste jiný čas odjezdu.',
          icon: Icons.train,
        ),
      );
    }
    if (exhausted) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.md),
        child: Text(
          'To jsou všechny spoje, které vyhledávač nabídl.',
          textAlign: TextAlign.center,
          style: context.texts.labelSmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      );
    }
    return const SizedBox(height: Sp.md);
  }
}

class _JourneyCard extends StatelessWidget {
  const _JourneyCard({required this.journey, required this.onTap});

  final Journey journey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FareEstimate? fare = journey.fare;

    return PtCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '${formatClock(journey.localDeparture)} → '
                '${clockWithDay(journey.localArrival, journey.localDeparture)}',
                style: context.texts.titleMedium,
              ),
              const Spacer(),
              Text(
                formatSpan(journey.durationMinutes),
                style: context.texts.bodyMedium,
              ),
            ],
          ),
          const SizedBox(height: Sp.xxs),
          Text(
            <String>[
              journey.isDirect
                  ? 'bez přestupu'
                  : '${journey.transfers} × přestup',
              if (journey.walkMinutes > 0) 'pěšky ${journey.walkMinutes} min',
              ..._lines(journey),
            ].join(' · '),
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          if (fare != null) ...<Widget>[
            const SizedBox(height: Sp.xxs),
            Text(
              // Vždycky „odhad". Přesné jízdné české veřejné dopravy zadarmo
              // nevydává nikdo a tvářit se jinak by bylo to jediné číslo na
              // obrazovce, podle kterého by se někdo zařídil.
              '≈ ${fare.min.round()}–${fare.max.round()} ${fare.currency} '
              '· odhad',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  /// Linky, ale nejvýš tři. Odpověď poskytovatele u pěti přestupů vypadá
  /// jako „Os 27813 · 000513 · 830800 · 846" — čtyři čísla, ze kterých si
  /// nikdo nic neodvodí, a karta kvůli nim naroste o dva řádky.
  static List<String> _lines(Journey j) {
    final List<String> names = <String>[];
    for (final JourneyLeg l in j.transitLegs) {
      final String? n = l.lineName;
      if (n == null || n.isEmpty || names.contains(n)) continue;
      names.add(n);
    }
    if (names.length <= 3) return names;
    return <String>[...names.take(3), '+${names.length - 3}'];
  }
}
