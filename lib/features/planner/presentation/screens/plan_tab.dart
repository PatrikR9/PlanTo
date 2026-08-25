import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/format/cs_format.dart';
import '../../../transport/presentation/widgets/destination_card.dart';
import '../../../trips/domain/trip.dart';
import '../../domain/journey.dart';
import '../../domain/plan_change.dart';
import '../../domain/plan_context.dart';
import '../../domain/plan_item.dart';
import '../../domain/plan_problem.dart';
import '../../domain/trip_plan.dart';
import '../plan_controller.dart';
import '../plan_strings.dart';
import '../widgets/journey_options_sheet.dart';
import '../widgets/plan_item_sheet.dart';
import '../widgets/plan_timeline.dart';

/// Záložka „Plán" — celý výlet chronologicky, a dá se do toho sáhnout.
///
/// Není to vygenerovaný itinerář ke čtení. Je to pracovní plocha: každý bod
/// se dá posunout, prodloužit, zamknout nebo smazat, a systém na to reaguje
/// přepočtem jenom té části, které se změna týká.
///
/// Doprava na ose je skutečná — jízdní řád z vyhledávače spojení, ne odhad
/// ze vzdálenosti. Když vyhledávač není zapnutý nebo neodpoví, je to na
/// obrazovce napsané; vymýšlet odjezd, který neexistuje, je jediné číslo,
/// podle kterého by se někdo doopravdy zařídil.
class PlanTab extends ConsumerWidget {
  const PlanTab({required this.trip, super.key});

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
    // Dvě různé prázdnoty, dvě různé cesty ven. „Nemáte termín" a „nemáte
    // cíl" vypadají v UI stejně, a kdyby se slily do jedné hlášky, polovina
    // lidí by klikala na tlačítko, které jim nepomůže.
    switch (state.gap) {
      case PlanContextGap.noDate:
        return ListView(
          padding: const EdgeInsets.all(Sp.xl),
          children: <Widget>[
            const SizedBox(height: Sp.xxl),
            PtEmptyState(
              title: 'Nejdřív termín',
              message: 'Plán se staví na konkrétní den — bez zamčeného '
                  'termínu není na kdy hledat spoje.',
              icon: Icons.event_available_outlined,
              actionLabel: 'Vybrat termín',
              onAction: () =>
                  context.go(Routes.tripDetail(trip.id, tab: 'dates')),
            ),
          ],
        );
      case PlanContextGap.noDestination:
        return ListView(
          padding: const EdgeInsets.all(Sp.xl),
          children: <Widget>[
            const SizedBox(height: Sp.xxl),
            NoDestinationView(trip: trip),
          ],
        );
      case PlanContextGap.none:
        break;
    }

    final TripPlan? plan = state.plan;
    final PlanContext? ctx = state.context;

    // Plán uložený na jiný den, než na jaký je teď zamčený termín.
    //
    // Nastane, když se termín přesune až po sestavení plánu. Přepočítat ho
    // potichu by znamenalo zahodit všechno, co si člověk nastavil, kvůli
    // rozhodnutí, které udělal někdo jiný na jiné záložce — a nechat ho tam
    // beze slova by byl plán na den, na který se nejede.
    // Termín, který už proběhl. Jízdní řády do minulosti nesahají, takže
    // vyhledávač takový dotaz odmítne — a odmítnout ho tady je lepší než ho
    // poslat a přeložit chybu zpátky. Porovnává se den v zóně zařízení; na
    // přesnost stačí, autoritou je stejně server.
    final bool datePassed = ctx != null && _isPast(ctx.planDate);

    final bool staleDate = plan != null &&
        plan.planDate != null &&
        ctx != null &&
        !_sameDay(plan.planDate!, ctx.planDate);

    return ListView(
      padding: const EdgeInsets.all(Sp.md),
      children: <Widget>[
        DestinationCard(trip: trip),
        const SizedBox(height: Sp.sm),

        if (state.isReplanning) const _ReplanningBar(),

        if (datePassed && (plan == null || plan.items.isEmpty))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.xxl),
            child: PtEmptyState(
              title: 'Termín už proběhl',
              message: 'Plán se staví na konkrétní den a ten je za námi. '
                  'Jízdní řády do minulosti nesahají — vyberte nový termín '
                  'a plán sestavíme na něj.',
              icon: Icons.history,
              actionLabel: 'Vybrat termín',
              onAction: () =>
                  context.go(Routes.tripDetail(trip.id, tab: 'dates')),
            ),
          )
        else if (plan == null || plan.items.isEmpty)
          _NotBuiltYet(
            isReplanning: state.isReplanning,
            onBuild: () => _controller(ref).rebuild(),
          )
        else ...<Widget>[
          _Constraints(
            plan: plan,
            onArriveBy: (TimeOfDay t) =>
                _setConstraint(ref, plan, t, home: false),
            onHomeBy: (TimeOfDay t) => _setConstraint(ref, plan, t, home: true),
          ),
          if (staleDate) ...<Widget>[
            const SizedBox(height: Sp.sm),
            _StaleDate(
              planDate: plan.planDate!,
              lockedDate: ctx.planDate,
              onRebuild:
                  state.isReplanning ? null : () => _controller(ref).rebuild(),
            ),
          ],
          if (plan.warnings.isNotEmpty) ...<Widget>[
            const SizedBox(height: Sp.sm),
            _Problems(problems: plan.warnings),
          ],
          const SizedBox(height: Sp.xs),
          PlanTimeline(
            plan: plan,
            changedIds: state.changedIds,
            onTapItem: (PlanItem item) => _openItem(context, ref, item),
            onAddAt: (DateTime start, Duration length) =>
                _addItem(context, ref, plan, start, length),
            onRefreshSegment: (PlanSegment s) =>
                _controller(ref).apply(RefreshSegment(s)),
          ),
          const SizedBox(height: Sp.md),
          _Summary(plan: plan, providerError: state.providerError),
          const SizedBox(height: Sp.sm),
          PtButton(
            label: 'Sestavit plán znovu',
            variant: PtButtonVariant.text,
            icon: Icons.refresh,
            onPressed: state.isReplanning || datePassed
                ? null
                : () => _controller(ref).rebuild(),
          ),
        ],

        const SizedBox(height: Sp.lg),
        TransportComparisonCard(trip: trip),

        // Atribuce zdrojů dat. U Transitousu to není zdvořilost, ale
        // podmínka použití — proto ji nese odpověď serveru a obrazovka ji jen
        // vypíše. Nedá se zapnout poskytovatel a zapomenout na ni.
        if (state.attribution case final String a) ...<Widget>[
          const SizedBox(height: Sp.sm),
          Text(
            a,
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  void _setConstraint(
    WidgetRef ref,
    TripPlan plan,
    TimeOfDay time, {
    required bool home,
  }) {
    final DateTime day = plan.planDate ?? DateTime.now();
    final DateTime local =
        DateTime(day.year, day.month, day.day, time.hour, time.minute);
    _controller(ref).apply(home ? SetHomeBy(local) : SetArriveBy(local));
  }

  Future<void> _openItem(
    BuildContext context,
    WidgetRef ref,
    PlanItem item,
  ) async {
    final PlanItemAction? action = await showPlanItemSheet(context, item);
    if (action == null || !context.mounted) return;

    switch (action) {
      case PlanItemApply(:final PlanChange change):
        await _controller(ref).apply(change);
      case PlanItemChooseJourney(:final PlanSegment segment):
        final Journey? picked = await showJourneySheet(
          context,
          title:
              segment == PlanSegment.homeward ? 'Spoje domů' : 'Spoje do cíle',
          search: _controller(ref).alternatives(segment),
        );
        if (picked == null) return;
        await _controller(ref).apply(ChooseJourney(segment, picked));
    }
  }

  Future<void> _addItem(
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
          // Vlastní bod je vždycky součástí pobytu. Do cesty tam ani zpět ho
          // nepustíme: ta se skládá z toho, co jede, ne z toho, co si někdo
          // dopsal.
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

/// Je ten den za námi? Půlnoc dneška je hranice — výlet, který se koná
/// dnes, se plánovat dá i odpoledne.
bool _isPast(DateTime day) {
  final DateTime now = DateTime.now();
  return DateTime(day.year, day.month, day.day)
      .isBefore(DateTime(now.year, now.month, now.day));
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Plán je na jiný den, než na jaký se teď jede.
class _StaleDate extends StatelessWidget {
  const _StaleDate({
    required this.planDate,
    required this.lockedDate,
    required this.onRebuild,
  });

  final DateTime planDate;
  final DateTime lockedDate;
  final VoidCallback? onRebuild;

  @override
  Widget build(BuildContext context) {
    final DateFormat fmt = DateFormat('d. M. y', 'cs');
    return Container(
      padding: const EdgeInsets.all(Sp.sm),
      decoration: BoxDecoration(
        color: context.colors.errorContainer,
        borderRadius: Radii.inputAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Tenhle plán je na ${fmt.format(planDate)}, ale jede se '
            '${fmt.format(lockedDate)}. Časy spojů proto neplatí.',
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onErrorContainer),
          ),
          const SizedBox(height: Sp.xs),
          PtButton(
            label: 'Sestavit plán na nový termín',
            variant: PtButtonVariant.tonal,
            icon: Icons.refresh,
            onPressed: onRebuild,
          ),
        ],
      ),
    );
  }
}

class _ReplanningBar extends StatelessWidget {
  const _ReplanningBar();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: Sp.xxs),
          Text(
            'Přepočítávám plán…',
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _NotBuiltYet extends StatelessWidget {
  const _NotBuiltYet({required this.isReplanning, required this.onBuild});

  final bool isReplanning;
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.xxl),
      child: PtEmptyState(
        title: 'Sestavíme plán?',
        message: 'Najdeme spoje tam i zpět a poskládáme z nich časovou osu '
            'celého dne. Pak si v ní můžete cokoli posunout.',
        icon: Icons.timeline,
        actionLabel: isReplanning ? null : 'Sestavit plán',
        onAction: isReplanning ? null : onBuild,
      ),
    );
  }
}

/// Zadání, podle kterého se hledá. Ne výsledek — proto stojí nad osou.
class _Constraints extends StatelessWidget {
  const _Constraints({
    required this.plan,
    required this.onArriveBy,
    required this.onHomeBy,
  });

  final TripPlan plan;
  final ValueChanged<TimeOfDay> onArriveBy;
  final ValueChanged<TimeOfDay> onHomeBy;

  @override
  Widget build(BuildContext context) {
    final DateTime? arrival = plan.arrivalAtDestination;
    final DateTime? home = plan.arrivalHome;
    final Duration off = plan.zoneOffset;

    return Wrap(
      spacing: Sp.xs,
      runSpacing: Sp.xs,
      children: <Widget>[
        _Chip(
          icon: Icons.flag_outlined,
          label: plan.arriveBy == null
              ? 'Dorazit do…'
              : 'Dorazit do '
                  '${formatClock(PlanItem.wallClockOf(plan.arriveBy!, off))}',
          onTap: () => _pick(
            context,
            plan.arriveBy ?? arrival,
            off,
            onArriveBy,
          ),
        ),
        _Chip(
          icon: Icons.home_outlined,
          label: plan.homeBy == null
              ? 'Být doma do…'
              : 'Doma do '
                  '${formatClock(PlanItem.wallClockOf(plan.homeBy!, off))}',
          onTap: () => _pick(context, plan.homeBy ?? home, off, onHomeBy),
        ),
      ],
    );
  }

  Future<void> _pick(
    BuildContext context,
    DateTime? initial,
    Duration offset,
    ValueChanged<TimeOfDay> onPicked,
  ) async {
    final DateTime seed = initial == null
        ? DateTime.now()
        : PlanItem.wallClockOf(initial, offset);
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: seed.hour, minute: seed.minute),
    );
    if (picked != null) onPicked(picked);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: onTap,
    );
  }
}

/// Co se nepovedlo splnit. Konkrétní věty s čísly, ne „něco se pokazilo".
class _Problems extends StatelessWidget {
  const _Problems({required this.problems});

  final List<PlanProblem> problems;

  @override
  Widget build(BuildContext context) {
    final bool blocking = problems.any((PlanProblem p) => p.isBlocking);

    return Container(
      padding: const EdgeInsets.all(Sp.sm),
      decoration: BoxDecoration(
        color: blocking
            ? context.colors.errorContainer
            : context.colors.surfaceContainerHighest,
        borderRadius: Radii.inputAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final PlanProblem p in problems)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.xxs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    p.isBlocking ? Icons.error_outline : Icons.info_outline,
                    size: 16,
                    color: blocking
                        ? context.colors.onErrorContainer
                        : context.colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: Sp.xs),
                  Expanded(
                    child: Text(
                      planProblemText(p),
                      style: context.texts.labelSmall?.copyWith(
                        color: blocking
                            ? context.colors.onErrorContainer
                            : context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.plan, this.providerError});

  final TripPlan plan;
  final String? providerError;

  @override
  Widget build(BuildContext context) {
    final DateTime? start = plan.items.firstOrNull?.localStart;
    final DateTime? end = plan.items.lastOrNull?.localEnd;
    final ({double min, double max})? cost = plan.cost;
    if (start == null || end == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(Sp.sm),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: Radii.inputAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Celkem ${formatClock(start)} – ${formatClock(end)} · '
            '${formatLength(end.difference(start).inMinutes)}',
            style: context.texts.bodyMedium,
          ),
          if (cost != null)
            Text(
              'Jízdné ≈ ${cost.min.round()}–${cost.max.round()} Kč '
              '· odhad, ne cena z pokladny',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          if (!plan.hasTimetable) ...<Widget>[
            Text(
              'Bez jízdního řádu — časy jsou odhad ze vzdálenosti. '
              'Konkrétní spoj najdete v IDOS.',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.error),
            ),
            // Rozdíl mezi „poskytovatel není zapnutý" a „poskytovatel
            // neodpověděl". První je nastavení, druhé je porucha, a bez téhle
            // věty vypadají na obrazovce stejně.
            Text(
              providerError == null
                  ? 'Vyhledávač jízdních řádů není zapnutý '
                      '(app_config.transport_provider = estimate).'
                  : 'Vyhledávač neodpověděl: $providerError',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Nový bod
// ---------------------------------------------------------------------------

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
          Text('Nový bod plánu', style: context.texts.titleMedium),
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
