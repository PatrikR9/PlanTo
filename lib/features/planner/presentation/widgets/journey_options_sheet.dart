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
  late Future<JourneySearch> _future = _run();

  Future<JourneySearch> _run() =>
      widget.lookup(_when, arriveBy: _arriveBy);

  void _search() => setState(() => _future = _run());

  /// Pozdější spoje se dají stránkovat přesně: zeptáme se na odjezdy po
  /// posledním, který jsme ukázali.
  void _later(JourneySearch r) {
    final Journey? last = r.journeys.isEmpty ? null : r.journeys.last;
    if (last == null) return;
    setState(() {
      _when = last.localDeparture.add(const Duration(minutes: 1));
      _arriveBy = false;
      _future = _run();
    });
  }

  /// Dřívější se stránkovat přesně nedají: vyhledávač umí „odjezdy po", ne
  /// „odjezdy před". Posuneme proto okno o hodinu zpátky. Výsledky se můžou
  /// s předchozí stránkou překrývat — což je lepší než přeskočit spoj, který
  /// mezi nimi jede.
  void _earlier(JourneySearch r) {
    final Journey? first = r.journeys.isEmpty ? null : r.journeys.first;
    final DateTime from = first?.localDeparture ?? _when;
    setState(() {
      _when = from.subtract(const Duration(hours: 1));
      _arriveBy = false;
      _future = _run();
    });
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
    setState(() {
      _when = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _when.hour,
        _when.minute,
      );
      _future = _run();
    });
  }

  Future<void> _pickTime() async {
    final DateTime? picked = await pickLocalTime(context, _when);
    if (picked == null) return;
    setState(() {
      _when = picked;
      _future = _run();
    });
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
          onSelectionChanged: (Set<bool> s) => setState(() {
            _arriveBy = s.first;
            _future = _run();
          }),
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

        FutureBuilder<JourneySearch>(
          future: _future,
          builder: (BuildContext context, AsyncSnapshot<JourneySearch> snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  PtSkeleton(height: 84),
                  SizedBox(height: Sp.xs),
                  PtSkeleton(height: 84),
                  SizedBox(height: Sp.xs),
                  PtSkeleton(height: 84),
                ],
              );
            }
            if (snap.hasError) {
              return PtErrorState(message: errorText(snap.error));
            }

            final JourneySearch result = snap.data ?? const JourneySearch.empty();
            if (result.isEmpty) {
              return Column(
                children: <Widget>[
                  const PtEmptyState(
                    title: 'Žádný spoj',
                    // Nikdy nepředstírat, že trasa existuje. Prázdný výsledek
                    // je odpověď, ne chyba k obejití.
                    message: 'Pro tenhle čas vyhledávač nenašel žádné '
                        'spojení. Zkuste jiný čas odjezdu.',
                    icon: Icons.train,
                  ),
                  const SizedBox(height: Sp.sm),
                  _Pager(
                    onEarlier: () => _earlier(result),
                    onLater: null,
                  ),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (!result.hasTimetable)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Sp.xs),
                    child: Text(
                      'Bez jízdního řádu — časy jsou odhad ze vzdálenosti.',
                      style: context.texts.labelSmall
                          ?.copyWith(color: context.colors.error),
                    ),
                  ),
                _Pager(
                  onEarlier: () => _earlier(result),
                  onLater: () => _later(result),
                ),
                const SizedBox(height: Sp.xs),
                for (final Journey j in result.journeys) ...<Widget>[
                  _JourneyCard(
                    journey: j,
                    isBest: j.id == result.bestId,
                    onTap: () => Navigator.of(context).pop(j),
                  ),
                  const SizedBox(height: Sp.xs),
                ],
                _Pager(
                  onEarlier: () => _earlier(result),
                  onLater: () => _later(result),
                ),
                if (result.attribution case final String a)
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
          },
        ),
      ],
    );
  }
}

/// Šipky na dřívější a pozdější spoje. V IDOS jsou nad seznamem i pod ním,
/// protože po odscrollování na konec je cesta nahoru zbytečná.
class _Pager extends StatelessWidget {
  const _Pager({required this.onEarlier, required this.onLater});

  final VoidCallback? onEarlier;
  final VoidCallback? onLater;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        PtButton(
          label: 'Dřívější',
          variant: PtButtonVariant.text,
          icon: Icons.keyboard_arrow_up,
          onPressed: onEarlier,
        ),
        PtButton(
          label: 'Pozdější',
          variant: PtButtonVariant.text,
          icon: Icons.keyboard_arrow_down,
          onPressed: onLater,
        ),
      ],
    );
  }
}

class _JourneyCard extends StatelessWidget {
  const _JourneyCard({
    required this.journey,
    required this.isBest,
    required this.onTap,
  });

  final Journey journey;
  final bool isBest;
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
              for (final JourneyLeg l in journey.transitLegs)
                if (l.lineName != null) l.lineName!,
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
          if (isBest) ...<Widget>[
            const SizedBox(height: Sp.xxs),
            Text(
              'Doporučeno',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.planto.availabilityFull),
            ),
          ],
        ],
      ),
    );
  }
}
