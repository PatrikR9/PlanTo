import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../trips/domain/trip.dart';
import '../../domain/plan_change.dart';
import '../../domain/plan_context.dart';
import '../../domain/plan_item.dart';
import '../../domain/program_suggestion.dart';
import '../../domain/trip_plan.dart';
import '../plan_controller.dart';
import '../plan_strings.dart';
import '../widgets/plan_item_sheet.dart';
import '../widgets/plan_timeline.dart';
import '../widgets/stay_window.dart';

/// Záložka „Program" — co se bude na místě dělat.
///
/// Oddělená od Plánu schválně. Plán odpovídá na „v kolik vyrážím a kdy jsem
/// doma"; ten se otvírá pořád a má se dát přečíst jedním pohledem. Program je
/// pracovní plocha: přidávání bodů, délky, poznámky, zámky. Kdyby to bylo na
/// jedné obrazovce, jedno z toho by tomu druhému překáželo — a překáželo,
/// dokud to tady nebylo.
///
/// Data jsou pořád jedna: položky se segmentem [PlanSegment.stay] v témže
/// plánu. Program není druhý plán, je to druhý pohled na týž.
class ProgramTab extends ConsumerWidget {
  const ProgramTab({required this.trip, super.key});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<Object?>(planErrorProvider, (Object? _, Object? error) {
      if (error == null) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(errorText(error))));
      ref.read(planErrorProvider.notifier).state = null;
    });

    final AsyncValue<PlanState> state =
        ref.watch(planControllerProvider(trip.id));

    return AsyncValueView<PlanState>(
      value: state,
      onRetry: () => ref.invalidate(planControllerProvider(trip.id)),
      data: (PlanState s) => _Body(trip: trip, state: s),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.trip, required this.state});

  final Trip trip;
  final PlanState state;

  PlanController _controller(WidgetRef ref) =>
      ref.read(planControllerProvider(trip.id).notifier);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TripPlan? plan = state.plan;

    // Program stojí na plánu: bez příjezdu a odjezdu není kam body zasadit.
    // Vlastní prázdný stav místo prázdné osy — „přidejte bod" na obrazovce,
    // kde se bod nemá kam přidat, je slepá ulička.
    if (state.gap != PlanContextGap.none ||
        plan == null ||
        plan.items.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(Sp.xl),
        children: <Widget>[
          const SizedBox(height: Sp.xxl),
          PtEmptyState(
            title: 'Nejdřív plán',
            message: 'Program se skládá do času mezi příjezdem a odjezdem. '
                'Sestavte plán cesty a pak sem přijďte vyplnit, co se bude '
                'dít.',
            icon: Icons.event_note_outlined,
            actionLabel: 'Otevřít Plán',
            onAction: () =>
                context.go(Routes.tripDetail(trip.id, tab: 'plan')),
          ),
        ],
      );
    }

    final List<PlanItem> items = plan.segment(PlanSegment.stay);
    final DateTime? from = plan.lastOutbound?.localEnd;
    final DateTime? to = plan.firstHomeward?.localStart;

    return ListView(
      padding: const EdgeInsets.all(Sp.md),
      children: <Widget>[
        if (state.isReplanning) ...<Widget>[
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: Sp.sm),
        ],

        StayWindow(
          plan: plan,
          lastDay: state.context?.returnDate,
          enabled: !state.isReplanning,
          onLeaveAt: (DateTime local) =>
              _controller(ref).apply(SetLeaveAt(local)),
        ),
        const SizedBox(height: Sp.md),

        if (items.isEmpty)
          PtEmptyState(
            title: 'Zatím prázdno',
            message: from == null || to == null
                ? 'Přidejte, co se bude na místě dít.'
                : 'Máte ${formatSpan(to.difference(from).inMinutes)} a zatím '
                    'na ně nic naplánovaného. Vyberte si z nabídky dole nebo '
                    'si přidejte vlastní bod.',
            icon: Icons.hiking,
          )
        else
          PlanTimeline(
            items: items,
            changedIds: state.changedIds,
            onTapItem: (PlanItem item) => _openItem(context, ref, item),
            onAddAt: (DateTime start, Duration length) =>
                _addCustom(context, ref, plan, start, length),
          ),

        const SizedBox(height: Sp.lg),
        _Suggestions(
          trip: trip,
          enabled: !state.isReplanning && from != null,
          onPick: (ProgramSuggestion s) => _addSuggestion(ref, plan, s),
        ),

        const SizedBox(height: Sp.md),
        PtButton(
          label: 'Vlastní bod',
          variant: PtButtonVariant.tonal,
          icon: Icons.add,
          expand: true,
          onPressed: state.isReplanning || from == null
              ? null
              : () => _addCustom(
                    context,
                    ref,
                    plan,
                    _nextFreeStart(plan) ?? from,
                    const Duration(hours: 1),
                  ),
        ),
        const SizedBox(height: Sp.xl),
      ],
    );
  }

  /// Kam zasadit další bod: za poslední naplánovaný, jinak hned po příjezdu.
  ///
  /// Skládat program odzadu dopředu nikdo nechce, a hledat volnou skulinu za
  /// uživatele by znamenalo hádat, kterou z nich myslel. Za poslední bod je
  /// jediné místo, které je pokaždé to očekávané.
  DateTime? _nextFreeStart(TripPlan plan) {
    final List<PlanItem> items = plan.segment(PlanSegment.stay);
    if (items.isEmpty) return plan.lastOutbound?.localEnd;
    return items.last.localEnd;
  }

  Future<void> _openItem(
    BuildContext context,
    WidgetRef ref,
    PlanItem item,
  ) async {
    final PlanChange? change = await showPlanItemSheet(context, item);
    if (change == null || !context.mounted) return;
    await _controller(ref).apply(change);
  }

  Future<void> _addSuggestion(
    WidgetRef ref,
    TripPlan plan,
    ProgramSuggestion s,
  ) async {
    final DateTime? start = _nextFreeStart(plan);
    if (start == null) return;

    await _controller(ref).apply(
      AddItem(
        PlanItem.atLocal(
          id: newPlanItemId(),
          kind: s.kind,
          segment: PlanSegment.stay,
          localStart: start,
          localEnd: start.add(s.length),
          zoneOffset: plan.zoneOffset,
          titleKey: kNamedItemKey,
          titleParams: <String, String>{'title': s.label},
          source: PlanItemSource.userCreated,
          // Délka je náš odhad, ne informace od skupiny. `exact` by tvrdila,
          // že turistika trvá právě tři hodiny.
          confidence: PlanConfidence.rough,
        ),
      ),
    );
  }

  Future<void> _addCustom(
    BuildContext context,
    WidgetRef ref,
    TripPlan plan,
    DateTime localStart,
    Duration length,
  ) async {
    final _NewItem? created = await showModalBottomSheet<_NewItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
      builder: (BuildContext context) => const _AddItemSheet(),
    );
    if (created == null || !context.mounted) return;

    final Duration span = length < const Duration(minutes: 30)
        ? length
        : const Duration(hours: 1);

    await _controller(ref).apply(
      AddItem(
        PlanItem.atLocal(
          id: newPlanItemId(),
          kind: created.kind,
          segment: PlanSegment.stay,
          localStart: localStart,
          localEnd: localStart.add(span),
          zoneOffset: plan.zoneOffset,
          titleKey: kNamedItemKey,
          titleParams: <String, String>{'title': created.title},
          source: PlanItemSource.userCreated,
          confidence: PlanConfidence.exact,
        ),
      ),
    );
  }
}

/// Nabídka podle toho, co si skupina zadala jako aktivity výletu.
class _Suggestions extends StatelessWidget {
  const _Suggestions({
    required this.trip,
    required this.enabled,
    required this.onPick,
  });

  final Trip trip;
  final bool enabled;
  final ValueChanged<ProgramSuggestion> onPick;

  @override
  Widget build(BuildContext context) {
    final List<ProgramSuggestion> all = suggestionsFor(trip.activityTags);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Co přidat', style: context.texts.labelLarge),
        const SizedBox(height: Sp.xxs),
        Text(
          trip.activityTags.isEmpty
              ? 'Výlet nemá zadané aktivity — v nastavení je můžete doplnit '
                  'a nabídka se podle nich přizpůsobí.'
              : 'Podle aktivit, které jste u výletu zadali. Délka je odhad, '
                  'po přidání se dá změnit.',
          style: context.texts.labelSmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        const SizedBox(height: Sp.xs),
        Wrap(
          spacing: Sp.xs,
          runSpacing: Sp.xs,
          children: <Widget>[
            for (final ProgramSuggestion s in all)
              ActionChip(
                avatar: Icon(planKindIcon(s.kind), size: 18),
                label: Text('${s.label} · ${formatSpan(s.length.inMinutes)}'),
                onPressed: enabled ? () => onPick(s) : null,
              ),
          ],
        ),
      ],
    );
  }
}

class _NewItem {
  const _NewItem(this.kind, this.title);
  final PlanItemKind kind;
  final String title;
}

class _AddItemSheet extends StatefulWidget {
  const _AddItemSheet();

  @override
  State<_AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends State<_AddItemSheet> {
  PlanItemKind _kind = PlanItemKind.activity;
  final TextEditingController _title = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: Sp.lg,
        right: Sp.lg,
        top: Sp.xs,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Sp.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Nový bod programu', style: context.texts.titleMedium),
          const SizedBox(height: Sp.md),
          Wrap(
            spacing: Sp.xs,
            children: <Widget>[
              for (final PlanItemKind k in kUserAddableKinds)
                ChoiceChip(
                  label: Text(planKindLabel(k)),
                  selected: _kind == k,
                  onSelected: (bool _) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: Sp.md),
          TextField(
            controller: _title,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Název',
              hintText: 'Prohlídka hradu',
            ),
            onSubmitted: (String _) => _done(),
          ),
          const SizedBox(height: Sp.md),
          PtButton(label: 'Přidat', expand: true, onPressed: _done),
        ],
      ),
    );
  }

  void _done() {
    final String title = _title.text.trim();
    Navigator.of(context).pop(
      _NewItem(_kind, title.isEmpty ? planKindLabel(_kind) : title),
    );
  }
}
