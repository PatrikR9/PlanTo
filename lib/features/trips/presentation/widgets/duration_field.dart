import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/format/cs_format.dart';
import '../../domain/trip.dart';

/// Jak dlouho výlet trvá — od čtvrthodiny po měsíc, jedním polem.
///
/// Předtím to byly dvě otázky: segment „Celý den / Pár hodin" a pod ním buď
/// tři přednastavené délky dnů, nebo osm délek v minutách do šesti hodin.
/// První z nich je otázka na implementaci — kdo řekne „na tři hodiny", už tím
/// odpověděl — a druhá neuměla ani týdenní dovolenou.
class DurationField extends StatelessWidget {
  const DurationField({
    required this.minutes,
    required this.onChanged,
    this.presets = kTripDurationPresets,
    super.key,
  });

  final int minutes;
  final ValueChanged<int> onChanged;
  final List<int> presets;

  @override
  Widget build(BuildContext context) {
    return PtCard(
      onTap: () async {
        final int? picked = await showModalBottomSheet<int>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (BuildContext _) =>
              _DurationSheet(minutes: minutes, presets: presets),
        );
        if (picked != null) onChanged(picked);
      },
      child: Row(
        children: <Widget>[
          const Icon(Icons.hourglass_bottom_outlined),
          const SizedBox(width: Sp.sm),
          Expanded(
            child: Text(
              formatDuration(minutes),
              style: context.texts.bodyLarge,
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

/// Nabízené délky. Pokrývají od kávy po dvoutýdenní dovolenou; cokoli mezi
/// tím se zadá vlastní hodnotou.
const List<int> kTripDurationPresets = <int>[
  30,
  60,
  90,
  120,
  180,
  240,
  360,
  1440,
  2 * 1440,
  3 * 1440,
  5 * 1440,
  7 * 1440,
  10 * 1440,
  14 * 1440,
];

/// Délky, které dávají smysl pro schůzku. Nikdo neplánuje třídenní meeting.
const List<int> kMeetingDurationPresets = <int>[
  15,
  30,
  45,
  60,
  90,
  120,
  180,
  240,
  480,
];

enum _Unit {
  minutes('minut', 1),
  hours('hodin', 60),
  days('dní', kDayMinutes);

  const _Unit(this.label, this.factor);

  final String label;
  final int factor;
}

class _DurationSheet extends StatefulWidget {
  const _DurationSheet({required this.minutes, required this.presets});

  final int minutes;
  final List<int> presets;

  @override
  State<_DurationSheet> createState() => _DurationSheetState();
}

class _DurationSheetState extends State<_DurationSheet> {
  late int _minutes = widget.minutes;
  late _Unit _unit = _unitFor(widget.minutes);
  late final TextEditingController _amount =
      TextEditingController(text: '${widget.minutes ~/ _unit.factor}');

  /// Vlastní hodnota se ukazuje rovnou, když zvolená délka není v nabídce —
  /// jinak by uživatel s desetidenní dovolenou musel hledat, kde ji předtím
  /// zadal.
  late bool _custom = !widget.presets.contains(widget.minutes);

  static _Unit _unitFor(int m) {
    if (m % kDayMinutes == 0) return _Unit.days;
    if (m % 60 == 0) return _Unit.hours;
    return _Unit.minutes;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _applyCustom() {
    final int? n = int.tryParse(_amount.text.trim());
    if (n == null) return;
    setState(() {
      _minutes = (n * _unit.factor)
          .clamp(kMinDurationMinutes, kMaxDurationMinutes)
          .toInt();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: Sp.md,
          right: Sp.md,
          bottom: MediaQuery.viewInsetsOf(context).bottom + Sp.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Jak dlouho', style: context.texts.titleMedium),
            const SizedBox(height: Sp.sm),
            Wrap(
              spacing: Sp.xs,
              runSpacing: Sp.xs,
              children: <Widget>[
                for (final int m in widget.presets)
                  ChoiceChip(
                    label: Text(formatDuration(m)),
                    selected: !_custom && _minutes == m,
                    onSelected: (_) => setState(() {
                      _custom = false;
                      _minutes = m;
                    }),
                  ),
                ChoiceChip(
                  label: const Text('Vlastní'),
                  selected: _custom,
                  onSelected: (_) => setState(() => _custom = true),
                ),
              ],
            ),
            if (_custom) ...<Widget>[
              const SizedBox(height: Sp.md),
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 96,
                    child: TextField(
                      controller: _amount,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: const InputDecoration(labelText: 'Kolik'),
                      onChanged: (_) => _applyCustom(),
                    ),
                  ),
                  const SizedBox(width: Sp.sm),
                  Expanded(
                    child: SegmentedButton<_Unit>(
                      segments: <ButtonSegment<_Unit>>[
                        for (final _Unit u in _Unit.values)
                          ButtonSegment<_Unit>(value: u, label: Text(u.label)),
                      ],
                      selected: <_Unit>{_unit},
                      showSelectedIcon: false,
                      onSelectionChanged: (Set<_Unit> s) {
                        setState(() => _unit = s.first);
                        _applyCustom();
                      },
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: Sp.md),
            Text(
              // Ta věta je celý důvod, proč se granularita nevybírá ručně:
              // řekne, co se stane, místo aby se na to ptala.
              _minutes < kDayMinutes
                  ? 'Najdeme konkrétní čas, který sedne všem.'
                  : 'Najdeme dny, které sednou všem.',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Sp.md),
            PtButton(
              label: 'Nastavit ${formatDuration(_minutes)}',
              expand: true,
              onPressed: () => Navigator.of(context).pop(_minutes),
            ),
            const SizedBox(height: Sp.sm),
          ],
        ),
      ),
    );
  }
}
