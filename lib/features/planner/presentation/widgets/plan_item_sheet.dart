import 'package:flutter/material.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/format/cs_format.dart';
import '../../domain/plan_change.dart';
import '../../domain/plan_item.dart';
import '../plan_strings.dart';

/// Detail položky: čas, délka, zámek, smazání.
///
/// Drag-and-drop tu není schválně. Na ose s minutovým rozlišením je tažení
/// prstem hádání; „Začátek: 14:00" v dialogu je přesné a dá se použít jednou
/// rukou v tramvaji. Priorita byla srozumitelná editace, ne efekt.
Future<PlanChange?> showPlanItemSheet(
  BuildContext context,
  PlanItem item,
) {
  return showModalBottomSheet<PlanChange>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
    builder: (BuildContext context) => _PlanItemSheet(item: item),
  );
}

class _PlanItemSheet extends StatefulWidget {
  const _PlanItemSheet({required this.item});

  final PlanItem item;

  @override
  State<_PlanItemSheet> createState() => _PlanItemSheetState();
}

class _PlanItemSheetState extends State<_PlanItemSheet> {
  late DateTime _start = widget.item.localStart;
  late Duration _length = widget.item.duration;
  late bool _locked = widget.item.isLocked;
  late final TextEditingController _title = TextEditingController(
    text: widget.item.titleParams['title'] ?? '',
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.item.titleParams['note'] ?? '',
  );

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _isTravel => widget.item.kind.isTravel;

  @override
  Widget build(BuildContext context) {
    final PlanItem item = widget.item;

    return Padding(
      padding: EdgeInsets.only(
        left: Sp.lg,
        right: Sp.lg,
        top: Sp.xs,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Sp.xl,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(planItemIcon(item), color: context.colors.primary),
                const SizedBox(width: Sp.sm),
                Expanded(
                  child: Text(
                    planItemTitle(item),
                    style: context.texts.titleMedium,
                  ),
                ),
              ],
            ),
            if (planItemSubtitle(item) case final String s)
              Padding(
                padding: const EdgeInsets.only(top: Sp.xxs),
                child: Text(
                  s,
                  style: context.texts.labelSmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: Sp.lg),

            // --- čas ---------------------------------------------------------
            if (_isTravel)
              const _Note(
                'Čas jízdy určuje jízdní řád, ne plán. Jiný spoj se vybírá '
                'v detailu cesty tam nebo zpět.',
              )
            else
              _Row(
                label: 'Začátek',
                value: formatClock(_start),
                onTap: _pickStart,
              ),

            if (item.canResize) ...<Widget>[
              const SizedBox(height: Sp.xs),
              _LengthRow(
                length: _length,
                onChanged: (Duration d) => setState(() => _length = d),
              ),
            ],

            // --- název a poznámka --------------------------------------------
            if (!_isTravel) ...<Widget>[
              const SizedBox(height: Sp.md),
              TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Název',
                  hintText: 'Prohlídka hradu',
                ),
              ),
              const SizedBox(height: Sp.xs),
              TextField(
                controller: _note,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Poznámka',
                  hintText: 'Rezervace na 10:00',
                ),
              ),
            ],

            // --- zámek --------------------------------------------------------
            const SizedBox(height: Sp.md),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _locked,
              onChanged: (bool v) => setState(() => _locked = v),
              title: const Text('Zamknout čas'),
              subtitle: const Text(
                'Zamčeným bodem automatický přepočet nehne. Hodí se na '
                'rezervaci nebo na cokoli, co má pevný čas.',
              ),
            ),

            const SizedBox(height: Sp.md),
            PtButton(
              label: 'Uložit',
              expand: true,
              onPressed: _save,
            ),
            if (item.canDelete) ...<Widget>[
              const SizedBox(height: Sp.xs),
              PtButton(
                label: 'Odstranit bod',
                variant: PtButtonVariant.text,
                icon: Icons.delete_outline,
                expand: true,
                onPressed: () => Navigator.of(context).pop(RemoveItem(item.id)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _pickStart() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _start.hour, minute: _start.minute),
    );
    if (picked == null) return;
    setState(() {
      _start = DateTime(
        _start.year,
        _start.month,
        _start.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  void _save() {
    final PlanItem item = widget.item;
    Navigator.of(context).pop(
      EditItem(
        item.id,
        // Doprava se neposouvá ručně — jinak by plán tvrdil, že vlak jede
        // o půl hodiny později, než jede.
        localStart: _isTravel ? null : _start,
        duration: item.canResize ? _length : null,
        title: _isTravel ? null : _title.text,
        note: _isTravel ? null : _note.text,
        locked: _locked,
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, required this.onTap});

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(child: Text(label, style: context.texts.bodyLarge)),
        PtButton(
          label: value,
          variant: PtButtonVariant.tonal,
          icon: Icons.schedule,
          onPressed: onTap,
        ),
      ],
    );
  }
}

class _LengthRow extends StatelessWidget {
  const _LengthRow({required this.length, required this.onChanged});

  final Duration length;
  final ValueChanged<Duration> onChanged;

  static const Duration _step = Duration(minutes: 15);
  static const Duration _min = Duration(minutes: 15);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(child: Text('Délka', style: context.texts.bodyLarge)),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline),
          tooltip: 'Zkrátit o 15 minut',
          onPressed:
              length - _step >= _min ? () => onChanged(length - _step) : null,
        ),
        SizedBox(
          width: 72,
          child: Text(
            formatLength(length.inMinutes),
            textAlign: TextAlign.center,
            style: context.texts.bodyLarge,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          tooltip: 'Prodloužit o 15 minut',
          onPressed: () => onChanged(length + _step),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Sp.sm),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: Radii.inputAll,
      ),
      child: Text(text, style: context.texts.labelSmall),
    );
  }
}
