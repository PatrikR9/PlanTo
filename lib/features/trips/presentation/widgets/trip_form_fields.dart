import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/format/cs_format.dart';
import '../../../transport/domain/transit_stop.dart';
import '../../../transport/presentation/widgets/stop_picker_sheet.dart';
import '../../domain/trip.dart';
import '../../domain/trip_draft.dart';
import 'activity_picker.dart';
import 'duration_field.dart';

/// Pole výletu, sdílená zakládáním a editací.
///
/// Bezstavová: mění přímo [draft] a hlásí to přes [onChanged]. Držet stav tady
/// by znamenalo, že editace musí formulář nejdřív naplnit — a naplnění, které
/// zapomene jedno pole, se pozná až tím, že se při uložení tiše vrátí na
/// výchozí hodnotu.
///
/// Název a rozpočet jdou přes controllery zvenčí schválně: přestavovat padesát
/// widgetů na každé písmeno je ta „Skipped frames" hláška z logu.
class TripFormFields extends StatelessWidget {
  const TripFormFields({
    required this.draft,
    required this.onChanged,
    required this.titleController,
    required this.budgetController,
    super.key,
  });

  final TripDraft draft;
  final VoidCallback onChanged;
  final TextEditingController titleController;
  final TextEditingController budgetController;

  bool get _meeting => draft.isMeeting;

  Future<void> _pickOrigin(BuildContext context) async {
    final TransitStop? picked = await pickTransitStop(
      context,
      title: 'Odkud jedete?',
    );
    if (picked == null) return;
    draft
      ..originLabel = picked.name
      ..originLat = picked.lat
      ..originLon = picked.lon
      ..originPlaceId = picked.id;
    onChanged();
  }

  Future<void> _pickRange(BuildContext context) async {
    final DateTime now = DateTime.now();
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
      currentDate: now,
      helpText: _meeting ? 'Kdy to připadá v úvahu?' : 'Kdy by se to hodilo?',
      saveText: 'Vybrat',
      initialDateRange: draft.windowStart == null || draft.windowEnd == null
          ? null
          : DateTimeRange(start: draft.windowStart!, end: draft.windowEnd!),
    );
    if (picked == null) return;
    draft
      ..windowStart = picked.start
      ..windowEnd = picked.end;
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final DateFormat fmt = DateFormat('d. M. y', 'cs');
    final String? error = draft.validationError;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: titleController,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Název',
            hintText: _meeting ? 'Sync k projektu' : 'Víkend na horách',
          ),
        ),
        const SizedBox(height: Sp.lg),

        if (!_meeting) ...<Widget>[
          const _Label('Odkud jedete'),
          PtCard(
            onTap: () => _pickOrigin(context),
            child: Row(
              children: <Widget>[
                const Icon(Icons.departure_board_outlined),
                const SizedBox(width: Sp.sm),
                Expanded(
                  child: Text(
                    draft.originLabel ?? 'Vyberte zastávku nebo nádraží',
                    style: context.texts.bodyLarge,
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
          const SizedBox(height: Sp.lg),
        ],

        const _Label('Kdy by se to hodilo'),
        PtCard(
          onTap: () => _pickRange(context),
          child: Row(
            children: <Widget>[
              const Icon(Icons.date_range_outlined),
              const SizedBox(width: Sp.sm),
              Expanded(
                child: Text(
                  draft.windowStart == null || draft.windowEnd == null
                      ? 'Vyberte rozmezí'
                      : '${fmt.format(draft.windowStart!)} – '
                          '${fmt.format(draft.windowEnd!)}',
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
        const SizedBox(height: Sp.lg),

        const _Label('Jak dlouho'),
        DurationField(
          minutes: draft.durationMinutes,
          presets: _meeting ? kMeetingDurationPresets : kTripDurationPresets,
          onChanged: (int m) {
            draft.durationMinutes = m;
            onChanged();
          },
        ),

        // Krok a použitelná část dne mají smysl jen tam, kde se hledá čas
        // uvnitř dne. U třídenního výletu by to byla dvě pole, která nic
        // neovlivní.
        if (draft.isTimed) ...<Widget>[
          const SizedBox(height: Sp.lg),
          const _Label('Po kolika minutách nabízet začátky'),
          SegmentedButton<int>(
            segments: <ButtonSegment<int>>[
              for (final int s in kSlotSteps)
                ButtonSegment<int>(value: s, label: Text('$s')),
            ],
            selected: <int>{draft.slotStepMinutes},
            showSelectedIcon: false,
            onSelectionChanged: (Set<int> s) {
              draft.slotStepMinutes = s.first;
              onChanged();
            },
          ),
          const SizedBox(height: Sp.xs),
          Text(
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
                  value: draft.dayStart,
                  onChanged: (Duration v) {
                    draft.dayStart = v;
                    if (draft.dayEnd <= v) {
                      draft.dayEnd = v + const Duration(hours: 1);
                    }
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: Sp.sm),
              Expanded(
                child: _TimeField(
                  label: 'Do',
                  value: draft.dayEnd,
                  onChanged: (Duration v) {
                    draft.dayEnd = v <= draft.dayStart
                        ? draft.dayStart + const Duration(hours: 1)
                        : v;
                    onChanged();
                  },
                ),
              ),
            ],
          ),
        ],

        if (!_meeting) ...<Widget>[
          const SizedBox(height: Sp.lg),
          const _Label('Doprava'),
          SegmentedButton<TransportPref>(
            segments: const <ButtonSegment<TransportPref>>[
              ButtonSegment<TransportPref>(
                value: TransportPref.public,
                label: Text('MHD/vlak'),
              ),
              ButtonSegment<TransportPref>(
                value: TransportPref.car,
                label: Text('Auto'),
              ),
              ButtonSegment<TransportPref>(
                value: TransportPref.either,
                label: Text('Je to jedno'),
              ),
            ],
            selected: <TransportPref>{draft.transport},
            onSelectionChanged: (Set<TransportPref> s) {
              draft.transport = s.first;
              onChanged();
            },
          ),
          const SizedBox(height: Sp.lg),
          const _Label('Co chcete dělat (volitelné)'),
          Text(
            'Podle toho se skládá seznam na sbalení a hodnotí se počasí.',
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Sp.xs),
          ActivityField(
            selected: draft.activityTags,
            onChanged: (Set<ActivityTag> s) {
              draft.activityTags = s;
              onChanged();
            },
          ),
          const SizedBox(height: Sp.lg),
          const _Label('Rozpočet na osobu (volitelné)'),
          TextField(
            controller: budgetController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(suffixText: 'Kč'),
          ),
        ],

        // Důvod, ne jen zašedlé tlačítko. Formulář, který mlčí, nechá člověka
        // hledat, které z osmi polí mu chybí.
        if (error != null && !_isJustEmpty(draft)) ...<Widget>[
          const SizedBox(height: Sp.md),
          Text(
            error,
            style:
                context.texts.labelSmall?.copyWith(color: context.colors.error),
          ),
        ],
      ],
    );
  }
}

/// Čerstvě otevřený formulář nemá co vyčítat.
bool _isJustEmpty(TripDraft d) =>
    d.windowStart == null && d.originLabel == null;

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Sp.xs),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(text, style: context.texts.labelLarge),
        ),
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
