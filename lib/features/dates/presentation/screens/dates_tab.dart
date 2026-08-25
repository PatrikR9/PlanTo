import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/format/cs_format.dart';
import '../../../availability/data/availability_repository.dart';
import '../../../availability/presentation/widgets/availability_strip.dart';
import '../../../trips/domain/trip.dart';
import '../../../trips/domain/trip_member.dart';
import '../../../trips/presentation/controllers/trips_controller.dart';
import '../../data/date_repository.dart';
import '../../domain/date_candidate.dart';
import '../dates_controller.dart';
import '../widgets/availability_grid.dart';
import '../widgets/date_candidate_card.dart';

/// The Dates tab — where the group actually decides.
///
/// Pořadí je záměr: nejdřív odpověď, potom práce. Nahoře lišta s tvarem
/// celého okna, pod ní jeden nejlepší návrh, a teprve po výběru dne plné
/// karty s hlasováním.
///
/// Lišta je ovladač, ne obrázek — viz [_CandidateListState]. Časovaný i
/// vícedenní výlet používají tutéž cestu: v obou případech je první otázka
/// „který den", jen se pod vybraným dnem ukáže víc časů, nebo jeden.
class DatesTab extends ConsumerWidget {
  const DatesTab({required this.trip, super.key});

  final Trip trip;

  Future<void> _mutate(
    BuildContext context,
    WidgetRef ref,
    Future<bool> Function() action,
  ) async {
    final bool ok = await action();
    if (ok) return;
    if (!context.mounted) return;

    final Object? error = ref.read(datesControllerProvider).error;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            errorText(error),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<DateCandidate>> candidates =
        ref.watch(dateCandidatesProvider(trip.id));
    final AsyncValue<List<DayAvailability>> strip =
        ref.watch(availabilityProvider(trip.id));
    final bool busy = ref.watch(datesControllerProvider).isLoading;

    // Nobody has answered yet, so every day would show as "everyone free" —
    // technically what the solver returns (an unknown schedule is treated as
    // free) and completely misleading as a proposal. Ask first.
    if (trip.calendarSharedCount == 0) {
      return _NothingYet(trip: trip);
    }

    return RefreshIndicator(
      onRefresh: () async {
        ref
          ..invalidate(dateCandidatesProvider(trip.id))
          ..invalidate(availabilityProvider(trip.id));
      },
      child: AsyncValueView<List<DateCandidate>>(
        value: candidates,
        onRetry: () => ref.invalidate(dateCandidatesProvider(trip.id)),
        isEmpty: (List<DateCandidate> c) => c.isEmpty,
        empty: () => _NothingYet(trip: trip),
        data: (List<DateCandidate> list) => _CandidateList(
          trip: trip,
          candidates: list,
          strip: strip.valueOrNull ?? const <DayAvailability>[],
          busy: busy,
          onVote: (DateCandidate c, DateVote? v) => _mutate(
            context,
            ref,
            () => ref.read(datesControllerProvider.notifier).vote(
                  tripId: trip.id,
                  startsAt: c.startsAt,
                  vote: v,
                ),
          ),
          onLock: (DateCandidate c) => _mutate(
            context,
            ref,
            () => ref
                .read(datesControllerProvider.notifier)
                .lock(tripId: trip.id, startsAt: c.startsAt),
          ),
          onUnlock: () => _mutate(
            context,
            ref,
            () => ref.read(datesControllerProvider.notifier).unlock(
                  tripId: trip.id,
                ),
          ),
        ),
      ),
    );
  }
}

class _CandidateList extends ConsumerStatefulWidget {
  const _CandidateList({
    required this.trip,
    required this.candidates,
    required this.strip,
    required this.busy,
    required this.onVote,
    required this.onLock,
    required this.onUnlock,
  });

  final Trip trip;
  final List<DateCandidate> candidates;
  final List<DayAvailability> strip;
  final bool busy;
  final void Function(DateCandidate candidate, DateVote? vote) onVote;
  final void Function(DateCandidate candidate) onLock;
  final VoidCallback onUnlock;

  @override
  ConsumerState<_CandidateList> createState() => _CandidateListState();
}

/// Lišta nahoře je navigace, ne obrázek.
///
/// Předtím tahle záložka ukázala pruh dnů a pod ním plnou kartu s hlasováním
/// pro každý den okna. U osmnáctidenního rozmezí to je osmnáct karet se
/// stejným skóre — žebříček, ve kterém nic nevede, a datum napsané dvakrát:
/// jednou v nadpisu dne, jednou v podtitulku karty.
///
/// Rozhodnutí, které tu člověk dělá, je nejdřív „který den" a teprve pak
/// „jak hlasuju". Obrazovka je teď rozdělená stejně: lišta vybírá den,
/// přehled ukáže jeden nejlepší návrh a pod ním jeden řádek na den, a plné
/// karty s hlasováním se objeví až po výběru dne.
class _CandidateListState extends ConsumerState<_CandidateList> {
  /// Vybraný den, nebo null pro přehled.
  ///
  /// Žije v obrazovce, ne v provideru: je to pohled na data, ne data. Po
  /// návratu z jiné záložky se má vrátit přehled, ne poslední filtr.
  DateTime? _selectedDay;

  /// Který filtr je nad seznamem časů. Výchozí je „dostupné": otázka, kvůli
  /// které sem člověk přišel, zní „kdy můžeme všichni", ne „kdy nemůžeme".
  _SlotFilter _filter = _SlotFilter.available;

  /// Seznam, nebo mřížka. Výchozí je seznam: dá se z něj hlasovat, kdežto
  /// mřížka odpovídá na jinou otázku — „jak to v tom týdnu vypadá".
  bool _grid = false;

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _selectDay(DateTime? day) {
    setState(() {
      // Druhé klepnutí na týž den výběr zruší. Bez toho je jediná cesta zpět
      // tlačítko, které je na malém displeji mimo dosah palce.
      final DateTime? current = _selectedDay;
      _selectedDay =
          day != null && current != null && _sameDay(day, current) ? null : day;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Trip trip = widget.trip;

    // Server řadí podle skóre, obrazovka podle času.
    //
    // Jsou to dvě různé práce. Seznam, který skáče 12. 9., 3. 11., 19. 9., je
    // seřazený správně a čte se jako šum — lidé prohlížejí data tak, jak je
    // ukazuje kalendář. Pořadí podle skóre proto přežívá jako jeden nejlepší
    // návrh nahoře, ne jako pořadí seznamu.
    final List<DateCandidate> byTime = <DateCandidate>[...widget.candidates]
      ..sort(
        (DateCandidate a, DateCandidate b) => a.startsAt.compareTo(b.startsAt),
      );
    final DateCandidate? best =
        widget.candidates.isEmpty ? null : widget.candidates.first;

    return Column(
      // Roztáhnout, ne vycentrovat. Předtím byl obsah v ListView, který děti
      // roztahuje sám; v Column je výchozí zarovnání na střed, takže nadpisy
      // sekcí odskočily doprostřed a vypadaly jako titulky, ne jako popisky.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (trip.isDateLocked)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.md, Sp.md, Sp.md, 0),
            child: _LockedBanner(trip: trip),
          ),
        const SizedBox(height: Sp.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.md),
          child: Row(
            children: <Widget>[
              const Expanded(child: _SectionLabel('Kdo kdy může')),
              // Dvě čtení téhož. Pruh dnů je ovladač seznamu, mřížka ukazuje
              // tvar celého okna — ani jedno nenahrazuje druhé, tak ať si
              // člověk vybere.
              IconButton(
                tooltip: _grid ? 'Zobrazit pruh dnů' : 'Zobrazit mřížku',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _grid ? Icons.view_day_outlined : Icons.grid_on_outlined,
                  size: 20,
                ),
                onPressed: () => setState(() => _grid = !_grid),
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.xs),
        // Nescrolluje pryč schválně: je to jediné místo, kde je vidět tvar
        // celého okna, a zároveň ovladač toho, co je pod ním.
        if (_grid)
          AvailabilityGrid(
            trip: trip,
            runs: widget.candidates,
            days: widget.strip,
            selectedDay: _selectedDay,
            onDayTap: _selectDay,
          )
        else
          AvailabilityStrip(
            days: widget.strip,
            selected: _selectedDay,
            onDayTap: (DayAvailability d) => _selectDay(d.day),
          ),
        const SizedBox(height: Sp.lg),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: Sp.xxl),
            children: _selectedDay == null
                ? _overview(context, byTime, best)
                : _oneDay(context, byTime, _selectedDay!, best),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- přehled --

  List<Widget> _overview(
    BuildContext context,
    List<DateCandidate> byTime,
    DateCandidate? best,
  ) {
    if (best == null) return _footer(context);

    final List<Widget> out = <Widget>[
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: Sp.md),
        child: _SectionLabel('Nejlepší návrh'),
      ),
      const SizedBox(height: Sp.xs),
      Padding(
        padding: const EdgeInsets.fromLTRB(Sp.md, 0, Sp.md, Sp.xs),
        child: _card(best, isBest: true),
      ),
    ];

    // Zbytek jako jeden řádek na den, i když je na něm časů víc. Počet
    // dalších časů se řekne slovem; rozbalí se výběrem dne.
    final List<DateCandidate> rest =
        byTime.where((DateCandidate c) => !_sameDay(c.day, best.day)).toList();
    if (rest.isEmpty) return out..addAll(_footer(context));

    out
      ..add(const SizedBox(height: Sp.md))
      ..add(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Sp.md),
          child: _SectionLabel('Další dny'),
        ),
      )
      ..add(const SizedBox(height: Sp.xs));

    DateTime? lastDay;
    for (final DateCandidate c in rest) {
      if (lastDay != null && _sameDay(c.day, lastDay)) continue;
      lastDay = c.day;
      final int onSameDay =
          rest.where((DateCandidate o) => _sameDay(o.day, c.day)).length;
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.md, 0, Sp.md, Sp.xxs),
          child: _DayRow(
            candidate: c,
            timed: widget.trip.isTimed,
            extraCount: onSameDay - 1,
            onTap: () => _selectDay(c.day),
          ),
        ),
      );
    }
    return out..addAll(_footer(context));
  }

  // -------------------------------------------------------- vybraný den --

  List<Widget> _oneDay(
    BuildContext context,
    List<DateCandidate> byTime,
    DateTime day,
    DateCandidate? best,
  ) {
    final List<Widget> out = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(Sp.md, 0, Sp.md, Sp.xs),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                capitalise(DateFormat('EEEE d. M.', 'cs').format(day)),
                style: context.texts.titleMedium,
              ),
            ),
            PtButton(
              label: 'Zobrazit vše',
              variant: PtButtonVariant.text,
              onPressed: () => _selectDay(null),
            ),
          ],
        ),
      ),
    ];

    // Vícedenní výlet: „slot" je celý den, takže se nabízí přesně to, co
    // spočítal solver. Filtr by tu neměl co filtrovat.
    if (!widget.trip.isTimed) {
      final List<DateCandidate> onDay =
          byTime.where((DateCandidate c) => _sameDay(c.day, day)).toList();
      if (onDay.isEmpty) {
        out.add(_noCandidate(context, day));
        return out..addAll(_footer(context));
      }
      for (final DateCandidate c in onDay) {
        out.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.md, 0, Sp.md, Sp.xs),
            child: _card(
              c,
              isBest: best != null && c.startsAt == best.startsAt,
              showDay: false,
            ),
          ),
        );
      }
      return out..addAll(_footer(context));
    }

    // Časový výlet: všechny časy dne, nesloučené.
    //
    // Přehled ukazuje sloučené běhy — „7:00–8:00, volno až do 21:00" — což je
    // pro seznam dnů správně, ale znamená, že se z celého okna nabídne jen
    // jeho začátek. Kdo chce začít v deset, nemá kam klepnout. Sem se proto
    // načte mřížka celého dne, a to až teď, po výběru dne.
    final AsyncValue<List<DateCandidate>> slots = ref.watch(
      daySlotsProvider(daySlotsKey(widget.trip.id, day)),
    );

    out
      ..add(
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.md, 0, Sp.md, Sp.sm),
          child: SegmentedButton<_SlotFilter>(
            segments: const <ButtonSegment<_SlotFilter>>[
              ButtonSegment<_SlotFilter>(
                value: _SlotFilter.available,
                label: Text('Dostupné'),
              ),
              ButtonSegment<_SlotFilter>(
                value: _SlotFilter.mismatch,
                label: Text('Neshoda'),
              ),
              ButtonSegment<_SlotFilter>(
                value: _SlotFilter.all,
                label: Text('Všechny'),
              ),
            ],
            selected: <_SlotFilter>{_filter},
            showSelectedIcon: false,
            onSelectionChanged: (Set<_SlotFilter> v) =>
                setState(() => _filter = v.first),
          ),
        ),
      )
      ..add(const SizedBox(height: Sp.xxs));

    final List<DateCandidate>? all = slots.valueOrNull;

    if (all == null) {
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.md, Sp.md, Sp.md, 0),
          child: slots.hasError
              ? Text(
                  errorText(slots.error),
                  style: context.texts.bodyMedium
                      ?.copyWith(color: context.colors.error),
                )
              : const Center(child: CircularProgressIndicator()),
        ),
      );
      return out..addAll(_footer(context));
    }

    // Počasí je denní, takže ho `trip_day_slots` nevrací — bylo by dvacetkrát
    // stejné. Přehled ho ale načtený má.
    DateCandidate? dayCandidate;
    for (final DateCandidate c in byTime) {
      if (_sameDay(c.day, day)) {
        dayCandidate = c;
        break;
      }
    }

    final List<DateCandidate> shown = all
        .where(
          (DateCandidate c) => switch (_filter) {
            _SlotFilter.available => c.everyoneFree,
            _SlotFilter.mismatch => !c.everyoneFree,
            _SlotFilter.all => true,
          },
        )
        .map((DateCandidate c) => c.withWeatherOf(dayCandidate))
        .toList();

    if (shown.isEmpty) {
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.md, Sp.sm, Sp.md, 0),
          child: Text(
            switch (_filter) {
              _SlotFilter.available =>
                'V tenhle den nevychází žádný čas, kdy můžou všichni. '
                    'Zkuste „Neshoda" — uvidíte, kdo v kterém čase nemůže.',
              _SlotFilter.mismatch =>
                'Žádný čas s neshodou — v tomhle dni vychází všem všechno.',
              _SlotFilter.all =>
                'Do tohohle dne se aktivita nevejde ani jednou.',
            },
            style: context.texts.bodyMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ),
      );
      return out..addAll(_footer(context));
    }

    for (final DateCandidate c in shown) {
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.md, 0, Sp.md, Sp.xs),
          child: _card(
            c,
            isBest: best != null && c.startsAt == best.startsAt,
            showDay: false,
          ),
        ),
      );
    }
    return out..addAll(_footer(context));
  }

  /// Den, na který solver nic nevymyslel.
  Widget _noCandidate(BuildContext context, DateTime day) {
    // RPC vrací jen nejlépe hodnocené termíny, takže volný den se mezi ně
    // nemusí vejít. Tvrdit tu „nikdo nemůže" by bylo rovnou nepravda — lišta
    // nad tím může ukazovat 5/5.
    DayAvailability? d;
    for (final DayAvailability x in widget.strip) {
      if (_sameDay(x.day, day)) {
        d = x;
        break;
      }
    }
    final String free =
        d == null ? '' : ' Volných je ${d.freeCount} z ${d.totalCount}.';

    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.md, Sp.sm, Sp.md, 0),
      child: Text(
        'Tenhle den se nevešel mezi nejlépe hodnocené návrhy.$free',
        style: context.texts.bodyMedium
            ?.copyWith(color: context.colors.onSurfaceVariant),
      ),
    );
  }

  // -------------------------------------------------------------- kusy ---

  Widget _card(
    DateCandidate c, {
    required bool isBest,
    bool showDay = true,
  }) {
    final Trip trip = widget.trip;
    // Jména se čtou tady, ne v kartě: jeden dotaz na obrazovku místo jednoho
    // na kartu, a karta zůstane bez závislosti na providerech.
    final Map<String, String> names = <String, String>{
      for (final TripMember m
          in ref.watch(tripMembersProvider(trip.id)).valueOrNull ??
              const <TripMember>[])
        m.userId: m.displayName,
    };
    return DateCandidateCard(
      names: names,
      showWeather: !trip.isMeeting,
      blockDays: trip.isTimed ? 1 : trip.durationDays,
      note: _breakdown(c),
      // Klíč drží stav prvku (a vlnku segmentového tlačítka) u správného
      // návrhu, když se seznam po hlasování přeskládá.
      key: ValueKey<DateTime>(c.startsAt),
      candidate: c,
      timed: trip.isTimed,
      showDay: showDay,
      isBest: isBest,
      busy: widget.busy,
      onVote: (DateVote? v) => widget.onVote(c, v),
      onLock: trip.isOrganiser ? () => widget.onLock(c) : null,
      onUnlock: trip.isOrganiser ? widget.onUnlock : null,
    );
  }

  /// „Po dnech: ne 16. 8. 5/5 · po 17. 8. 4/5."
  ///
  /// Existuje jen kvůli tomu, že mřížka a karta počítají jinou věc. Mřížka
  /// ukazuje jeden den, karta celý pobyt — a člověk, kterému jedno z čísel
  /// nesedí, potřebuje vidět, který den ten rozdíl dělá.
  String? _breakdown(DateCandidate c) {
    final Trip trip = widget.trip;
    if (trip.isTimed || trip.durationDays <= 1) return null;

    final DateFormat fmt = DateFormat('E d. M.', 'cs');
    final List<String> parts = <String>[];
    for (int i = 0; i < trip.durationDays; i++) {
      final DateTime d = c.day.add(Duration(days: i));
      for (final DayAvailability x in widget.strip) {
        if (_sameDay(x.day, d)) {
          parts.add('${fmt.format(d)} ${x.freeCount}/${x.totalCount}');
          break;
        }
      }
    }
    if (parts.length < 2) return null;
    return 'Po dnech: ${parts.join(' · ')}';
  }

  List<Widget> _footer(BuildContext context) => <Widget>[
        const SizedBox(height: Sp.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.md),
          child: PtButton(
            label: 'Upravit moji dostupnost',
            variant: PtButtonVariant.text,
            icon: Icons.edit_calendar_outlined,
            expand: true,
            onPressed: () => context.push(Routes.availability(widget.trip.id)),
          ),
        ),
      ];
}

/// Jeden den v přehledu.
///
/// Kompaktní schválně: v tomhle kroku se vybírá den, ne hlasuje. Hlasovací
/// tlačítka na dvaceti kartách naráz nejsou nabídka, jsou to dvacet
/// rozhodnutí, o která nikdo nežádal.
class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.candidate,
    required this.timed,
    required this.extraCount,
    required this.onTap,
  });

  final DateCandidate candidate;
  final bool timed;

  /// Kolik dalších časů ten den ještě je. Nula u vícedenních výletů.
  final int extraCount;

  final VoidCallback onTap;

  static Duration _since(DateTime t) =>
      Duration(hours: t.hour, minutes: t.minute);

  @override
  Widget build(BuildContext context) {
    final DateCandidate c = candidate;
    final Color accent = c.everyoneFree
        ? context.planto.availabilityFull
        : c.freeCount == 0
            ? context.planto.availabilityNone
            : context.planto.availabilityPartial;

    final String detail = <String>[
      if (timed)
        '${formatWallClock(_since(c.localStart))} – '
            '${formatWallClock(_since(c.localEnd))}',
      if (extraCount == 1) 'a 1 další čas',
      if (extraCount > 1 && extraCount < 5) 'a $extraCount další časy',
      if (extraCount >= 5) 'a $extraCount dalších časů',
      if (c.isWeekend) 'víkend',
      if (c.isHoliday) 'svátek',
    ].join(' · ');

    return PtCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: Sp.md,
        vertical: Sp.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  capitalise(DateFormat('EEEE d. M.', 'cs').format(c.day)),
                  style: context.texts.bodyLarge,
                ),
                if (detail.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Sp.xxs),
                  Text(
                    detail,
                    style: context.texts.labelSmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          Text(
            '${c.freeCount}/${c.totalCount}',
            style: context.texts.labelLarge?.copyWith(color: accent),
          ),
          const SizedBox(width: Sp.xs),
          Icon(
            Icons.chevron_right,
            size: 18,
            color: context.colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: context.texts.labelLarge);
}

class _NothingYet extends StatelessWidget {
  const _NothingYet({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(Sp.xl),
      children: <Widget>[
        const SizedBox(height: Sp.xxl),
        PtEmptyState(
          title: 'Zatím není co spočítat',
          message: 'Řekněte nám, kdy nemůžete — z kalendáře nebo ručně — '
              'a navrhneme termíny, které sednou celé skupině.',
          icon: Icons.calendar_month_outlined,
          actionLabel: 'Zadat dostupnost',
          onAction: () => context.push(Routes.availability(trip.id)),
        ),
      ],
    );
  }
}

class _LockedBanner extends StatelessWidget {
  const _LockedBanner({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final DateTime start = trip.lockedStart!;
    final DateTime? end = trip.lockedEnd;

    final String when;
    if (trip.isTimed) {
      final String dayLabel =
          capitalise(DateFormat('EEEE d. M.', 'cs').format(start));
      final String from = formatWallClock(
        Duration(hours: start.hour, minutes: start.minute),
      );
      final String to = end == null
          ? ''
          : ' – ${formatWallClock(
              Duration(hours: end.hour, minutes: end.minute),
            )}';
      when = '$dayLabel, $from$to';
    } else {
      // locked_range is half-open, so the last day of the trip is end - 1.
      // Showing the exclusive bound would tell people to come home a day late.
      final DateTime? lastDay = end?.subtract(const Duration(days: 1));
      final DateFormat fmt = DateFormat('EEEE d. M. y', 'cs');
      when = lastDay != null && lastDay.isAfter(start)
          ? '${capitalise(fmt.format(start))} – ${fmt.format(lastDay)}'
          : capitalise(fmt.format(start));
    }

    return PtCard(
      child: Row(
        children: <Widget>[
          Icon(Icons.event_available, color: context.planto.availabilityFull),
          const SizedBox(width: Sp.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Termín je domluvený', style: context.texts.labelLarge),
                const SizedBox(height: Sp.xxs),
                Text(when, style: context.texts.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Filtr nad časy jednoho dne.
///
/// „Neshoda" je vlastní volba, ne jen doplněk k „dostupné": termín, kde jeden
/// z pěti nemůže, je pořád použitelný — organizátor se jen potřebuje
/// rozhodnout vědomě a vidět, koho se to týká.
enum _SlotFilter { available, mismatch, all }
