import 'package:flutter/material.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/format/cs_format.dart';
import '../../domain/plan_change.dart';
import '../../domain/plan_item.dart';
import '../plan_strings.dart';
import 'time_picking.dart';

/// Detail bodu programu: název, druh, začátek, konec, poznámka, zámek.
///
/// Drag-and-drop tu není schválně. Na ose s minutovým rozlišením je tažení
/// prstem hádání; „Začátek: 14:00" v dialogu je přesné a dá se použít jednou
/// rukou v tramvaji. Priorita byla srozumitelná editace, ne efekt.
///
/// Začátek i konec jsou samostatná pole. Dřív tu byl začátek a délka, což
/// znamenalo, že „posuň konec na šest" se muselo v hlavě přepočítat na
/// délku — a při každé změně začátku se konec potichu posunul s ním.
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
  late PlanItemKind _kind = widget.item.kind;
  late DateTime _start = widget.item.localStart;
  late DateTime _end = widget.item.localEnd;
  late bool _locked = widget.item.isLocked;

  /// Předvyplněno tím, co je na ose. Prázdné pole u bodu, který se jmenuje
  /// „Program v Krumlově", vypadá jako chyba — a přepsat název znamená ho
  /// nejdřív vidět.
  late final TextEditingController _title = TextEditingController(
    text: widget.item.titleParams['title']?.trim().isNotEmpty ?? false
        ? widget.item.titleParams['title']
        : planItemTitle(widget.item),
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.item.titleParams['note'] ?? '',
  );

  static const List<Duration> _presets = <Duration>[
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(minutes: 90),
    Duration(hours: 2),
    Duration(hours: 3),
    Duration(hours: 4),
  ];

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _isTravel => widget.item.kind.isTravel;

  Duration get _length => _end.difference(_start);

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
                Icon(planKindIcon(_kind), color: context.colors.primary),
                const SizedBox(width: Sp.sm),
                Expanded(
                  child: Text(
                    planItemTitle(item),
                    style: context.texts.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Sp.lg),

            if (_isTravel)
              const _Note(
                'Čas jízdy určuje jízdní řád, ne plán. Jiný spoj se vybírá '
                'v detailu cesty tam nebo zpět.',
              )
            else ...<Widget>[
              // --- název a druh ---------------------------------------------
              TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Název',
                  hintText: 'Prohlídka hradu',
                ),
              ),
              const SizedBox(height: Sp.sm),
              Wrap(
                spacing: Sp.xs,
                children: <Widget>[
                  for (final PlanItemKind k in kUserAddableKinds)
                    ChoiceChip(
                      avatar: Icon(planKindIcon(k), size: 18),
                      label: Text(planKindLabel(k)),
                      selected: _kind == k,
                      onSelected: (bool _) => setState(() => _kind = k),
                    ),
                ],
              ),

              // --- časy ------------------------------------------------------
              const SizedBox(height: Sp.md),
              _TimeRow(
                label: 'Začátek',
                value: _start,
                onPick: _pickStart,
                onNudge: (Duration d) => setState(() {
                  _start = _start.add(d);
                  // Posun začátku bere konec s sebou. Kdo posouvá začátek,
                  // posouvá celý bod; zkrátit ho je jiná akce a má vlastní
                  // pole.
                  _end = _end.add(d);
                }),
              ),
              const SizedBox(height: Sp.xs),
              _TimeRow(
                label: 'Konec',
                value: _end,
                onPick: _pickEnd,
                onNudge: (Duration d) => setState(() {
                  final DateTime next = _end.add(d);
                  if (next.isAfter(_start)) _end = next;
                }),
              ),

              const SizedBox(height: Sp.xs),
              Row(
                children: <Widget>[
                  Text(
                    'Délka ${formatSpan(_length.inMinutes)}',
                    style: context.texts.labelSmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: Sp.xs),
              Wrap(
                spacing: Sp.xs,
                runSpacing: Sp.xs,
                children: <Widget>[
                  for (final Duration d in _presets)
                    ChoiceChip(
                      label: Text(formatSpan(d.inMinutes)),
                      selected: _length == d,
                      onSelected: (bool _) =>
                          setState(() => _end = _start.add(d)),
                    ),
                ],
              ),

              const SizedBox(height: Sp.md),
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
              onPressed: _length > Duration.zero ? _save : null,
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
    final DateTime? picked = await pickLocalTime(context, _start);
    if (picked == null) return;
    final Duration keep = _length;
    setState(() {
      _start = picked;
      _end = picked.add(keep);
    });
  }

  Future<void> _pickEnd() async {
    final DateTime? picked = await pickLocalTime(context, _end);
    if (picked == null) return;
    // Konec před začátkem znamená přes půlnoc. Program, který má trvat minus
    // dvě hodiny, je vždycky překlep — den se proto přičte.
    setState(() {
      _end = picked.isAfter(_start)
          ? picked
          : picked.add(const Duration(days: 1));
    });
  }

  void _save() {
    final PlanItem item = widget.item;
    Navigator.of(context).pop(
      EditItem(
        item.id,
        kind: _isTravel ? null : _kind,
        // Doprava se neposouvá ručně — jinak by plán tvrdil, že vlak jede
        // o půl hodiny později, než jede.
        localStart: _isTravel ? null : _start,
        duration: _isTravel ? null : _length,
        title: _isTravel ? null : _title.text,
        note: _isTravel ? null : _note.text,
        locked: _locked,
      ),
    );
  }
}

/// Čas s šipkami po čtvrthodině a přesným výběrem.
class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.label,
    required this.value,
    required this.onPick,
    required this.onNudge,
  });

  final String label;
  final DateTime value;
  final VoidCallback onPick;
  final ValueChanged<Duration> onNudge;

  static const Duration _step = Duration(minutes: 15);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(child: Text(label, style: context.texts.bodyLarge)),
        IconButton(
          icon: const Icon(Icons.remove),
          tooltip: 'O čtvrt hodiny dřív',
          onPressed: () => onNudge(-_step),
        ),
        PtButton(
          label: formatClock(value),
          variant: PtButtonVariant.tonal,
          icon: Icons.schedule,
          onPressed: onPick,
        ),
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: 'O čtvrt hodiny později',
          onPressed: () => onNudge(_step),
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
