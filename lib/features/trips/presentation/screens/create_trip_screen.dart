import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/format/cs_format.dart';
import '../../domain/czech_cities.dart';
import '../../domain/trip.dart';
import '../../domain/trip_repository.dart';
import '../controllers/trips_controller.dart';

/// One scrolling form, not the three-step wizard in architecture section 4.
///
/// Deliberate deviation: there are six meaningful fields and four of them have
/// good defaults. A wizard would turn one scroll into three screens and two
/// extra taps, which contradicts the product's first principle. If the field
/// count grows past about ten, revisit.
class CreateTripScreen extends ConsumerStatefulWidget {
  const CreateTripScreen({super.key});

  @override
  ConsumerState<CreateTripScreen> createState() => _CreateTripScreenState();
}

class _CreateTripScreenState extends ConsumerState<CreateTripScreen> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _budget = TextEditingController();

  OriginCity _origin = kOriginCities.first;
  DateTimeRange? _range;
  int _duration = 1;
  TransportPref _transport = TransportPref.either;
  final Set<ActivityTag> _tags = <ActivityTag>{};

  TripGranularity _granularity = TripGranularity.day;
  int _slotMinutes = 120;
  int _slotStep = 30;
  Duration _dayStart = const Duration(hours: 7);
  Duration _dayEnd = const Duration(hours: 21);

  /// Mirrors the server guard. Time mode generates a row per
  /// (day × slot × participant), so a year-long window at a 15-minute step is
  /// 35 000 slots and a screen nobody can read.
  static const int _maxTimeModeDays = 42;

  @override
  void dispose() {
    _title.dispose();
    _budget.dispose();
    super.dispose();
  }

  int get _windowDays =>
      _range == null ? 0 : _range!.end.difference(_range!.start).inDays + 1;

  bool get _windowTooLongForSlots =>
      _granularity == TripGranularity.time && _windowDays > _maxTimeModeDays;

  bool get _valid =>
      _title.text.trim().isNotEmpty &&
      _range != null &&
      !_windowTooLongForSlots;

  Future<void> _pickRange() async {
    final DateTime now = DateTime.now();
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
      currentDate: now,
      helpText: 'Kdy by se to hodilo?',
      saveText: 'Vybrat',
      initialDateRange: _range,
    );
    if (picked != null) setState(() => _range = picked);
  }

  Future<void> _submit() async {
    final DateTimeRange range = _range!;
    final String? id =
        await ref.read(createTripControllerProvider.notifier).submit(
              NewTrip(
                title: _title.text.trim(),
                originLabel: _origin.name,
                originLat: _origin.lat,
                originLon: _origin.lon,
                windowStart: range.start,
                // The picker returns midnight of the last day; a trip on the
                // final day of the window would otherwise be excluded.
                windowEnd: range.end.add(const Duration(days: 1)),
                durationDays: _duration,
                transport: _transport,
                granularity: _granularity,
                slotMinutes:
                    _granularity == TripGranularity.time ? _slotMinutes : null,
                slotStepMinutes: _slotStep,
                dayStart: _dayStart,
                dayEnd: _dayEnd,
                budgetPerPerson: double.tryParse(
                  _budget.text.trim().replaceAll(',', '.'),
                ),
                activityTags: _tags.toList(),
              ),
            );

    if (!mounted || id == null) return;
    // Straight into the new trip: the moment after creating is when the
    // organiser wants to share the link.
    context.pushReplacement(Routes.tripDetail(id));
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<void> state = ref.watch(createTripControllerProvider);
    final DateFormat fmt = DateFormat('d. M. y', 'cs');

    ref.listen<AsyncValue<void>>(createTripControllerProvider,
        (AsyncValue<void>? _, AsyncValue<void> next) {
      if (!next.hasError) return;
      final Object e = next.error!;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text(e is Failure ? e.userMessage : Failure.genericMessage),
        ),);
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Nový výlet')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Sp.md),
          children: <Widget>[
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Název',
                hintText: 'Víkend na horách',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Sp.lg),
            const _Label('Odkud jedete'),
            DropdownButtonFormField<OriginCity>(
              initialValue: _origin,
              items: <DropdownMenuItem<OriginCity>>[
                for (final OriginCity c in kOriginCities)
                  DropdownMenuItem<OriginCity>(value: c, child: Text(c.name)),
              ],
              onChanged: (OriginCity? c) =>
                  setState(() => _origin = c ?? _origin),
            ),
            const SizedBox(height: Sp.lg),
            const _Label('Kdy by se to hodilo'),
            PtCard(
              onTap: _pickRange,
              child: Row(
                children: <Widget>[
                  const Icon(Icons.date_range_outlined),
                  const SizedBox(width: Sp.sm),
                  Expanded(
                    child: Text(
                      _range == null
                          ? 'Vyberte rozmezí'
                          : '${fmt.format(_range!.start)} – '
                              '${fmt.format(_range!.end)}',
                      style: context.texts.bodyLarge,
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
            const SizedBox(height: Sp.sm),
            Text(
              'Klidně široké rozmezí — čím širší, tím spíš najdeme termín '
              'pro všechny.',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            if (_windowTooLongForSlots) ...<Widget>[
              const SizedBox(height: Sp.xs),
              Text(
                'Na hodiny se dá plánovat nejvýš $_maxTimeModeDays dnů '
                'dopředu. Zkraťte rozmezí, nebo přepněte na celé dny.',
                style: context.texts.labelSmall
                    ?.copyWith(color: context.colors.error),
              ),
            ],
            const SizedBox(height: Sp.lg),
            const _Label('Co plánujete'),
            SegmentedButton<TripGranularity>(
              segments: const <ButtonSegment<TripGranularity>>[
                ButtonSegment<TripGranularity>(
                  value: TripGranularity.day,
                  label: Text('Celý den'),
                  icon: Icon(Icons.wb_sunny_outlined),
                ),
                ButtonSegment<TripGranularity>(
                  value: TripGranularity.time,
                  label: Text('Pár hodin'),
                  icon: Icon(Icons.schedule),
                ),
              ],
              selected: <TripGranularity>{_granularity},
              onSelectionChanged: (Set<TripGranularity> s) =>
                  setState(() => _granularity = s.first),
            ),
            const SizedBox(height: Sp.sm),
            Text(
              _granularity == TripGranularity.day
                  ? 'Najdeme dny, které sednou všem.'
                  : 'Najdeme konkrétní čas — na kino, oběd nebo večerní '
                      'procházku.',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Sp.lg),
            if (_granularity == TripGranularity.day) ...<Widget>[
              const _Label('Jak dlouho'),
              SegmentedButton<int>(
                segments: const <ButtonSegment<int>>[
                  ButtonSegment<int>(value: 1, label: Text('1 den')),
                  ButtonSegment<int>(value: 2, label: Text('2 dny')),
                  ButtonSegment<int>(value: 3, label: Text('3+ dny')),
                ],
                selected: <int>{_duration},
                onSelectionChanged: (Set<int> s) =>
                    setState(() => _duration = s.first),
              ),
            ] else ...<Widget>[
              const _Label('Jak dlouho to potrvá'),
              DropdownButtonFormField<int>(
                initialValue: _slotMinutes,
                items: <DropdownMenuItem<int>>[
                  for (final int m in kSlotLengths)
                    DropdownMenuItem<int>(
                      value: m,
                      child: Text(formatLength(m)),
                    ),
                ],
                onChanged: (int? m) =>
                    setState(() => _slotMinutes = m ?? _slotMinutes),
              ),
              const SizedBox(height: Sp.lg),
              const _Label('Po kolika minutách nabízet začátky'),
              SegmentedButton<int>(
                segments: <ButtonSegment<int>>[
                  for (final int s in kSlotSteps)
                    ButtonSegment<int>(value: s, label: Text('$s')),
                ],
                selected: <int>{_slotStep},
                showSelectedIcon: false,
                onSelectionChanged: (Set<int> s) =>
                    setState(() => _slotStep = s.first),
              ),
              const SizedBox(height: Sp.xs),
              Text(
                // The trade-off, stated once, so nobody has to guess.
                'Po 15 minutách vyjde přesnější čas, po 60 kratší seznam.',
                style: context.texts.labelSmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              const SizedBox(height: Sp.lg),
              const _Label('V kolik to připadá v úvahu'),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _TimeField(
                      label: 'Od',
                      value: _dayStart,
                      onChanged: (Duration v) => setState(() {
                        _dayStart = v;
                        if (_dayEnd <= v) {
                          _dayEnd = v + const Duration(hours: 1);
                        }
                      }),
                    ),
                  ),
                  const SizedBox(width: Sp.sm),
                  Expanded(
                    child: _TimeField(
                      label: 'Do',
                      value: _dayEnd,
                      onChanged: (Duration v) => setState(() {
                        _dayEnd = v <= _dayStart
                            ? _dayStart + const Duration(hours: 1)
                            : v;
                      }),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: Sp.lg),
            const _Label('Doprava'),
            SegmentedButton<TransportPref>(
              segments: const <ButtonSegment<TransportPref>>[
                ButtonSegment<TransportPref>(
                    value: TransportPref.public, label: Text('MHD/vlak'),),
                ButtonSegment<TransportPref>(
                    value: TransportPref.car, label: Text('Auto'),),
                ButtonSegment<TransportPref>(
                    value: TransportPref.either, label: Text('Je to jedno'),),
              ],
              selected: <TransportPref>{_transport},
              onSelectionChanged: (Set<TransportPref> s) =>
                  setState(() => _transport = s.first),
            ),
            const SizedBox(height: Sp.lg),
            const _Label('Co chcete dělat'),
            Wrap(
              spacing: Sp.xs,
              runSpacing: Sp.xs,
              children: <Widget>[
                for (final ActivityTag t in ActivityTag.values)
                  FilterChip(
                    label: Text(_tagLabel(t)),
                    selected: _tags.contains(t),
                    onSelected: (bool on) => setState(
                      () => on ? _tags.add(t) : _tags.remove(t),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Sp.lg),
            const _Label('Rozpočet na osobu (volitelné)'),
            TextField(
              controller: _budget,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(suffixText: 'Kč'),
            ),
            const SizedBox(height: Sp.xxl),
            PtButton(
              label: 'Vytvořit a pozvat',
              expand: true,
              isLoading: state.isLoading,
              onPressed: _valid ? _submit : null,
            ),
            const SizedBox(height: Sp.xl),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Sp.xs),
        child: Text(text, style: context.texts.labelLarge),
      );
}

/// A wall-clock time, stored as a [Duration] since midnight rather than a
/// [DateTime] because it is not a moment — it is "seven o'clock", on any day.
class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Duration value;
  final ValueChanged<Duration> onChanged;

  Future<void> _pick(BuildContext context) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: value.inHours,
        minute: value.inMinutes % 60,
      ),
      helpText: label,
    );
    if (picked == null) return;
    onChanged(Duration(hours: picked.hour, minutes: picked.minute));
  }

  @override
  Widget build(BuildContext context) {
    return PtCard(
      onTap: () => _pick(context),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: context.texts.labelSmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
                Text(formatWallClock(value), style: context.texts.bodyLarge),
              ],
            ),
          ),
          const Icon(Icons.schedule, size: 18),
        ],
      ),
    );
  }
}

String _tagLabel(ActivityTag t) => switch (t) {
      ActivityTag.hiking => 'Turistika',
      ActivityTag.city => 'Město',
      ActivityTag.lake => 'Voda',
      ActivityTag.castle => 'Hrady',
      ActivityTag.museum => 'Muzea',
      ActivityTag.cafe => 'Kavárny',
      ActivityTag.festival => 'Festivaly',
      ActivityTag.viewpoint => 'Vyhlídky',
    };
