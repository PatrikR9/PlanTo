import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/format/cs_format.dart';
import '../../../trips/domain/trip.dart';
import '../../../trips/presentation/controllers/trips_controller.dart';
import '../../data/availability_repository.dart';
import '../../data/device_calendar_source.dart';
import '../../domain/manual_busy_block.dart';
import '../availability_controller.dart';
import '../widgets/availability_chooser.dart';
import '../widgets/calendar_feed_card.dart';
import '../widgets/name_gate.dart';

/// Screen 21 — one place to say when you cannot make it, filled either way.
///
/// The two paths are not alternatives on different screens. Importing the
/// calendar drops its busy blocks straight into this grid, where they can be
/// corrected; typing them in by hand starts from an empty one. That matters
/// because the calendar is never quite right — it does not know about the
/// dentist you have not booked yet — and because it removes the single point
/// of failure in an unproven Kotlin plugin.
///
/// It asks the inverse question, when you *cannot*, because that list is
/// almost always the shorter one and it is how people hold their own diary.
class ManualAvailabilityScreen extends ConsumerStatefulWidget {
  const ManualAvailabilityScreen({required this.tripId, super.key});

  final String tripId;

  @override
  ConsumerState<ManualAvailabilityScreen> createState() =>
      _ManualAvailabilityScreenState();
}

class _ManualAvailabilityScreenState
    extends ConsumerState<ManualAvailabilityScreen> {
  List<ManualBusyBlock> _blocks = <ManualBusyBlock>[];
  bool _prefilled = false;

  /// The grid is hidden until somebody asks for it. Most invitees never do:
  /// they tap "Připojit kalendář" and the screen closes. Showing a month of
  /// day chips to all of them made the fast path look like the slow one.
  bool _showEditor = false;

  /// Set once the name has been given in this session, so the gate does not
  /// reappear while the provider refetches.
  bool _named = false;

  List<ManualBusyBlock> _forDay(DateTime day) =>
      _blocks.where((ManualBusyBlock b) => b.day == day).toList();

  void _replaceDay(DateTime day, List<ManualBusyBlock> next) {
    setState(() {
      _blocks = <ManualBusyBlock>[
        ..._blocks.where((ManualBusyBlock b) => b.day != day),
        ...next,
      ]..sort((ManualBusyBlock a, ManualBusyBlock b) {
          final int byDay = a.day.compareTo(b.day);
          if (byDay != 0) return byDay;
          return (a.from ?? Duration.zero).compareTo(b.from ?? Duration.zero);
        });
    });
  }

  void _toggleWholeDay(DateTime day) {
    final List<ManualBusyBlock> existing = _forDay(day);
    _replaceDay(
      day,
      existing.isEmpty
          ? <ManualBusyBlock>[ManualBusyBlock.allDay(day)]
          : <ManualBusyBlock>[],
    );
  }

  Future<void> _editDay(DateTime day, Trip trip) async {
    final List<ManualBusyBlock>? next =
        await showModalBottomSheet<List<ManualBusyBlock>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DayEditorSheet(
        day: day,
        blocks: _forDay(day),
        dayStart: trip.dayStart,
        dayEnd: trip.dayEnd,
      ),
    );
    if (next != null) _replaceDay(day, next);
  }

  /// Re-import from the editor, for somebody who typed a few days in and then
  /// decided the calendar was easier after all.
  Future<void> _importCalendar(Trip trip) async {
    final bool ok =
        await ref.read(calendarSyncControllerProvider.notifier).sync(
              tripId: trip.id,
              windowStart: trip.windowStart,
              windowEnd: trip.windowEnd,
            );
    if (!mounted) return;

    if (ok) {
      // The controller wrote straight to the server, so re-read rather than
      // guess. Letting the prefill run again is the whole point.
      setState(() => _prefilled = false);
      ref.invalidate(myBlocksProvider(widget.tripId));
      return;
    }

    final Object? error = ref.read(calendarSyncControllerProvider).error;
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

  Future<void> _save() async {
    final bool ok = await ref
        .read(manualAvailabilityControllerProvider.notifier)
        .save(tripId: widget.tripId, blocks: _blocks);

    if (!mounted) return;

    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }

    final Object? error = ref.read(manualAvailabilityControllerProvider).error;
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
  Widget build(BuildContext context) {
    final AsyncValue<Trip> trip = ref.watch(tripProvider(widget.tripId));
    final AsyncValue<List<ManualBusyBlock>> saved =
        ref.watch(myBlocksProvider(widget.tripId));
    final bool busy = ref.watch(manualAvailabilityControllerProvider).isLoading;

    // Prefill once, when the saved blocks land. initState is too early (the
    // data is not there) and every build would fight the user's taps.
    if (!_prefilled && saved.hasValue) {
      _prefilled = true;
      _blocks = List<ManualBusyBlock>.of(saved.requireValue);
    }

    // Somebody who has answered before lands straight in the editor: they
    // came back to change something, not to be asked again.
    final bool editing = _showEditor || _blocks.isNotEmpty;

    // Ask who they are exactly once, before anything else on this screen.
    // Identical on Android and on the web, because it is the same question
    // and the answer is what the organiser reads on the Dates tab.
    final AsyncValue<String?> name = ref.watch(myDisplayNameProvider);
    final bool askName = !_named && needsName(name.valueOrNull);

    if (name.hasValue && askName) {
      return Scaffold(
        appBar: AppBar(title: const Text('Vaše dostupnost')),
        body: NameGate(onDone: () => setState(() => _named = true)),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Vaše dostupnost')),
      // Nested rather than combined: the grid must not accept a tap before
      // the previous selection has landed, or the prefill would arrive on top
      // of what the user just did and silently re-tick days they cleared.
      body: AsyncValueView<Trip>(
        value: trip,
        onRetry: () => ref.invalidate(tripProvider(widget.tripId)),
        data: (Trip t) => AsyncValueView<List<ManualBusyBlock>>(
          value: saved,
          onRetry: () => ref.invalidate(myBlocksProvider(widget.tripId)),
          data: (List<ManualBusyBlock> _) => editing
              ? _Body(
                  trip: t,
                  blocks: _blocks,
                  enabled: !busy,
                  // The web has no calendar API at all. Offering a button
                  // that cannot work is worse than not offering it: they tap
                  // it, nothing happens, and they conclude the app is broken
                  // rather than that this one path is unavailable.
                  canImport: ref.watch(calendarSourceProvider).isSupported,
                  onImport: () => _importCalendar(t),
                  onDayTap: (DateTime day) =>
                      t.isTimed ? _editDay(day, t) : _toggleWholeDay(day),
                )
              : AvailabilityChooser(
                  trip: t,
                  onManual: () => setState(() => _showEditor = true),
                  onLink: () async {
                    final bool ok =
                        await promptForCalendarFeed(context, ref, t.id);
                    // A link is saved and synced by the function itself, so
                    // there is nothing left to confirm here either.
                    if (ok && mounted) Navigator.of(context).pop(true);
                  },
                  onConnected: () => Navigator.of(context).pop(true),
                ),
        ),
      ),
      // No save bar on the chooser: there is nothing on it to save, and a
      // disabled button at the bottom of a two-button screen just reads as
      // another thing to get past.
      bottomNavigationBar: !editing
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(Sp.md, 0, Sp.md, Sp.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    _summary(_blocks),
                    style: context.texts.labelSmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: Sp.xs),
                  PtButton(
                    // Saving nothing is a real answer, and the most useful
                    // one: "I'm free the whole time". Never disabled.
                    label: 'Uložit dostupnost',
                    expand: true,
                    isLoading: busy,
                    onPressed: _save,
                  ),
                ],
              ),
            ),
    );
  }

  static String _summary(List<ManualBusyBlock> blocks) {
    if (blocks.isEmpty) return 'Nic neoznačeno — můžete kdykoliv';
    final int days = blocks.map((ManualBusyBlock b) => b.day).toSet().length;
    return switch (days) {
      1 => 'Máte zabráno 1 den',
      2 || 3 || 4 => 'Máte zabráno $days dny',
      _ => 'Máte zabráno $days dnů',
    };
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.trip,
    required this.blocks,
    required this.enabled,
    required this.canImport,
    required this.onImport,
    required this.onDayTap,
  });

  final Trip trip;
  final List<ManualBusyBlock> blocks;
  final bool enabled;
  final bool canImport;
  final VoidCallback onImport;
  final void Function(DateTime day) onDayTap;

  @override
  Widget build(BuildContext context) {
    final DateFormat monthFmt = DateFormat('LLLL y', 'cs');

    // Group the window into months for headings. LinkedHashMap iteration
    // order is insertion order, so the months come out chronologically.
    final Map<String, List<DateTime>> byMonth = <String, List<DateTime>>{};
    DateTime cursor = DateTime(
      trip.windowStart.year,
      trip.windowStart.month,
      trip.windowStart.day,
    );
    final DateTime last = DateTime(
      trip.windowEnd.year,
      trip.windowEnd.month,
      trip.windowEnd.day,
    );
    while (!cursor.isAfter(last)) {
      byMonth
          .putIfAbsent(monthFmt.format(cursor), () => <DateTime>[])
          .add(cursor);
      // Adding 24 hours breaks on the DST change; this is the only correct way.
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
    }

    return ListView(
      padding: const EdgeInsets.all(Sp.md),
      children: <Widget>[
        if (canImport) ...<Widget>[
          PtCard(
            child: Row(
              children: <Widget>[
                Icon(Icons.sync, color: context.planto.availabilityFull),
                const SizedBox(width: Sp.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Načíst z kalendáře',
                        style: context.texts.labelLarge,
                      ),
                      const SizedBox(height: Sp.xxs),
                      Text(
                        'Vyplní se samo. Pak to tady můžete upravit.',
                        style: context.texts.labelSmall
                            ?.copyWith(color: context.colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                PtButton(
                  label: 'Načíst',
                  variant: PtButtonVariant.tonal,
                  onPressed: enabled ? onImport : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: Sp.sm),
        ],
        // No "sorry, not on the web" any more: the link works everywhere, so
        // in the browser it simply becomes the first option instead of the
        // second.
        CalendarFeedCard(tripId: trip.id),
        const SizedBox(height: Sp.lg),
        Text(
          trip.isTimed
              ? 'Klepněte na den a řekněte, kdy nemůžete. Ostatní uvidí jen '
                  'počet volných lidí, ne vaše bloky.'
              : 'Klepněte na dny, kdy nemůžete. Ostatní uvidí jen počet '
                  'volných lidí, ne které dny jste označili.',
          style: context.texts.bodyMedium
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        const SizedBox(height: Sp.lg),
        for (final String label in byMonth.keys) ...<Widget>[
          Text(capitalise(label), style: context.texts.labelLarge),
          const SizedBox(height: Sp.xs),
          Wrap(
            spacing: Sp.xs,
            runSpacing: Sp.xs,
            children: <Widget>[
              for (final DateTime day in byMonth[label]!)
                _DayChip(
                  day: day,
                  blocks: blocks
                      .where((ManualBusyBlock b) => b.day == day)
                      .toList(),
                  onTap: enabled ? () => onDayTap(day) : null,
                ),
            ],
          ),
          const SizedBox(height: Sp.lg),
        ],
      ],
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.day,
    required this.blocks,
    required this.onTap,
  });

  final DateTime day;
  final List<ManualBusyBlock> blocks;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool isWeekend = day.weekday >= DateTime.saturday;
    final bool allDay = blocks.any((ManualBusyBlock b) => b.isAllDay);
    final bool partial = blocks.isNotEmpty && !allDay;
    final bool anyBusy = blocks.isNotEmpty;
    final Color accent = context.planto.availabilityFull;

    final String detail = allDay
        ? 'celý den'
        : partial
            ? _rangeLabel(blocks)
            : '';

    return Semantics(
      button: true,
      selected: anyBusy,
      label: '${DateFormat('EEEE d. MMMM', 'cs').format(day)}, '
          '${allDay ? "nemůžu celý den" : partial ? "nemůžu $detail" : "můžu"}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.cardAll,
        child: AnimatedContainer(
          duration: Motion.micro,
          curve: Motion.enter,
          width: 64,
          height: 66,
          padding: const EdgeInsets.symmetric(horizontal: Sp.xxs),
          decoration: BoxDecoration(
            color: anyBusy
                ? context.colors.errorContainer
                : accent.withValues(alpha: 0.12),
            borderRadius: Radii.cardAll,
            border: Border.all(
              color: anyBusy ? context.colors.error : context.planto.hairline,
              width: anyBusy ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                DateFormat('E', 'cs').format(day),
                style: context.texts.labelSmall?.copyWith(
                  color: isWeekend
                      ? context.colors.primary
                      : context.colors.onSurfaceVariant,
                ),
              ),
              Text(
                '${day.day}.',
                style: context.texts.titleSmall?.copyWith(
                  color: anyBusy ? context.colors.onErrorContainer : null,
                ),
              ),
              // Colour is never the only signal (architecture section 7.4).
              if (detail.isEmpty)
                Icon(Icons.check, size: 12, color: accent)
              else
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.labelSmall?.copyWith(
                    fontSize: 9,
                    color: context.colors.onErrorContainer,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _rangeLabel(List<ManualBusyBlock> blocks) {
    if (blocks.length > 1) return '${blocks.length} bloky';
    final ManualBusyBlock b = blocks.first;
    return '${formatWallClock(b.from ?? Duration.zero)}–'
        '${formatWallClock(b.to ?? Duration.zero)}';
  }
}

/// Time-mode editor for a single day: all day, or a list of from–to blocks.
class _DayEditorSheet extends StatefulWidget {
  const _DayEditorSheet({
    required this.day,
    required this.blocks,
    required this.dayStart,
    required this.dayEnd,
  });

  final DateTime day;
  final List<ManualBusyBlock> blocks;
  final Duration dayStart;
  final Duration dayEnd;

  @override
  State<_DayEditorSheet> createState() => _DayEditorSheetState();
}

class _DayEditorSheetState extends State<_DayEditorSheet> {
  late List<ManualBusyBlock> _blocks = List<ManualBusyBlock>.of(widget.blocks);

  bool get _allDay => _blocks.any((ManualBusyBlock b) => b.isAllDay);

  Future<void> _addBlock() async {
    final TimeOfDay? from = await showTimePicker(
      context: context,
      helpText: 'Od kolika nemůžete',
      initialTime: TimeOfDay(
        hour: widget.dayStart.inHours,
        minute: widget.dayStart.inMinutes % 60,
      ),
    );
    if (from == null || !mounted) return;

    final TimeOfDay? to = await showTimePicker(
      context: context,
      helpText: 'Do kolika',
      initialTime: TimeOfDay(hour: (from.hour + 2) % 24, minute: from.minute),
    );
    if (to == null || !mounted) return;

    final Duration f = Duration(hours: from.hour, minutes: from.minute);
    Duration t = Duration(hours: to.hour, minutes: to.minute);
    // Midnight as an end time means "until the end of the day", not "zero
    // minutes long". Anything else that runs backwards is a mistake.
    if (t <= f) t = const Duration(hours: 24);

    setState(() {
      _blocks = <ManualBusyBlock>[
        ..._blocks.where((ManualBusyBlock b) => !b.isAllDay),
        ManualBusyBlock(day: widget.day, from: f, to: t),
      ]..sort(
          (ManualBusyBlock a, ManualBusyBlock b) => a.from!.compareTo(b.from!),
        );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: Sp.xl,
        right: Sp.xl,
        top: Sp.md,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Sp.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            capitalise(DateFormat('EEEE d. M.', 'cs').format(widget.day)),
            style: context.texts.titleLarge,
          ),
          const SizedBox(height: Sp.md),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Celý den nemůžu'),
            value: _allDay,
            onChanged: (bool on) => setState(() {
              _blocks = on
                  ? <ManualBusyBlock>[ManualBusyBlock.allDay(widget.day)]
                  : <ManualBusyBlock>[];
            }),
          ),
          if (!_allDay) ...<Widget>[
            const Divider(),
            for (final ManualBusyBlock b in _blocks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.schedule, size: 18),
                title: Text(
                  '${formatWallClock(b.from!)} – ${formatWallClock(b.to!)}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Odebrat',
                  onPressed: () => setState(
                    () => _blocks =
                        _blocks.where((ManualBusyBlock x) => x != b).toList(),
                  ),
                ),
              ),
            PtButton(
              label: 'Přidat čas',
              variant: PtButtonVariant.text,
              icon: Icons.add,
              onPressed: _addBlock,
            ),
          ],
          const SizedBox(height: Sp.md),
          PtButton(
            label: 'Hotovo',
            expand: true,
            onPressed: () => Navigator.of(context).pop(_blocks),
          ),
        ],
      ),
    );
  }
}
