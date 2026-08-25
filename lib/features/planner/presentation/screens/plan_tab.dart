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
import '../../domain/plan_change.dart';
import '../../domain/plan_context.dart';
import '../../domain/plan_item.dart';
import '../../domain/plan_problem.dart';
import '../../domain/travel_outline.dart';
import '../../domain/trip_plan.dart';
import '../plan_controller.dart';
import '../plan_strings.dart';
import '../widgets/plan_item_sheet.dart';
import '../widgets/plan_timeline.dart';
import '../widgets/travel_card.dart';
import '../widgets/travel_sheet.dart';

/// Záložka „Plán" — den výletu ve třech kusech: tam, na místě, zpět.
///
/// Cesta tam a zpět jsou karty se základními časy. Celý průběh — nástupiště,
/// přestupy, pěší přechody — je za klepnutím, ne pod ním: kdo otevře plán,
/// řeší nejdřív „v kolik vyrážím a kdy jsem doma". Rozepsat mu rovnou dvacet
/// řádků znamená, že tu první odpověď musí hledat.
///
/// Prostředek je pracovní plocha: každý bod programu se dá posunout,
/// prodloužit, zamknout nebo smazat, a systém na to reaguje přepočtem jenom
/// té části, které se změna týká.
///
/// Doprava je skutečná — jízdní řád z vyhledávače spojení, ne odhad ze
/// vzdálenosti. Když vyhledávač není zapnutý nebo neodpoví, je to na
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
              message: 'Plán se staví na konkrétní den — bez vybraného '
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

    // Termín, který už proběhl. Jízdní řády do minulosti nesahají, takže
    // vyhledávač takový dotaz odmítne — a odmítnout ho tady je lepší než ho
    // poslat a přeložit chybu zpátky. Porovnává se den v zóně zařízení; na
    // přesnost stačí, autoritou je stejně server.
    final bool datePassed = ctx != null && _isPast(ctx.planDate);

    // Plán uložený na jiný den, než na jaký je teď vybraný termín.
    //
    // Nastane, když se termín přesune až po sestavení plánu. Přepočítat ho
    // potichu by znamenalo zahodit všechno, co si člověk nastavil, kvůli
    // rozhodnutí, které udělal někdo jiný na jiné záložce — a nechat ho tam
    // beze slova by byl plán na den, na který se nejede.
    final bool staleDate = plan != null &&
        plan.planDate != null &&
        ctx != null &&
        !_sameDay(plan.planDate!, ctx.planDate);

    return ListView(
      padding: const EdgeInsets.all(Sp.md),
      children: <Widget>[
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
          if (staleDate) ...<Widget>[
            _StaleDate(
              planDate: plan.planDate!,
              lockedDate: ctx.planDate,
              onRebuild:
                  state.isReplanning ? null : () => _controller(ref).rebuild(),
            ),
            const SizedBox(height: Sp.sm),
          ],
          if (plan.warnings.isNotEmpty) ...<Widget>[
            _Problems(problems: plan.warnings),
            const SizedBox(height: Sp.sm),
          ],

          TravelCard(
            segment: PlanSegment.outbound,
            outline: outlineFor(plan.segment(PlanSegment.outbound)),
            isChanged: _segmentChanged(plan, PlanSegment.outbound),
            onTap: () => showTravelSheet(
              context,
              tripId: trip.id,
              segment: PlanSegment.outbound,
            ),
          ),

          const SizedBox(height: Sp.md),
          _StayHeader(plan: plan),
          const SizedBox(height: Sp.xs),
          _StayBody(
            plan: plan,
            changedIds: state.changedIds,
            onTapItem: (PlanItem item) => _openItem(context, ref, item),
            onAddAt: (DateTime start, Duration length) =>
                _addItem(context, ref, plan, start, length),
          ),
          const SizedBox(height: Sp.md),

          TravelCard(
            segment: PlanSegment.homeward,
            outline: outlineFor(plan.segment(PlanSegment.homeward)),
            isChanged: _segmentChanged(plan, PlanSegment.homeward),
            onTap: () => showTravelSheet(
              context,
              tripId: trip.id,
              segment: PlanSegment.homeward,
            ),
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

  /// Hnul přepočet s tímhle úsekem cesty? Karta to musí říct, i když je
  /// detail zavřený — jinak by se spoj vyměnil a nikdo by se to nedozvěděl.
  bool _segmentChanged(TripPlan plan, PlanSegment segment) => plan
      .segment(segment)
      .any((PlanItem i) => state.changedIds.contains(i.id));

  Future<void> _openItem(
    BuildContext context,
    WidgetRef ref,
    PlanItem item,
  ) async {
    final PlanChange? change = await showPlanItemSheet(context, item);
    if (change == null || !context.mounted) return;
    await _controller(ref).apply(change);
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

/// Nadpis prostřední části: co se dá stihnout mezi příjezdem a odjezdem.
class _StayHeader extends StatelessWidget {
  const _StayHeader({required this.plan});

  final TripPlan plan;

  @override
  Widget build(BuildContext context) {
    final DateTime? from = plan.lastOutbound?.localEnd;
    final DateTime? to = plan.firstHomeward?.localStart;
    final String window = from == null || to == null
        ? ''
        : ' · ${formatClock(from)} – ${formatClock(to)} '
            '(${formatLength(to.difference(from).inMinutes)})';

    return Text('Na místě$window', style: context.texts.labelLarge);
  }
}

/// Program mezi příjezdem a odjezdem. Když v něm nic není, je to nabídka,
/// ne prázdný blok — čas na místě je to jediné, co se na výletě opravdu
/// plánuje.
class _StayBody extends StatelessWidget {
  const _StayBody({
    required this.plan,
    required this.changedIds,
    required this.onTapItem,
    required this.onAddAt,
  });

  final TripPlan plan;
  final Set<String> changedIds;
  final void Function(PlanItem item) onTapItem;
  final void Function(DateTime localStart, Duration length) onAddAt;

  @override
  Widget build(BuildContext context) {
    final List<PlanItem> items = plan.segment(PlanSegment.stay);
    final DateTime? from = plan.lastOutbound?.localEnd;
    final DateTime? to = plan.firstHomeward?.localStart;

    if (items.isEmpty) {
      final Duration free = from == null || to == null
          ? const Duration(hours: 1)
          : to.difference(from);
      return PtCard(
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                from == null
                    ? 'Zatím tu nic není.'
                    : 'Volno ${formatLength(free.inMinutes)}. Co se bude dít?',
                style: context.texts.bodyMedium,
              ),
            ),
            PtButton(
              label: 'Přidat bod',
              variant: PtButtonVariant.text,
              icon: Icons.add,
              onPressed: from == null ? null : () => onAddAt(from, free),
            ),
          ],
        ),
      );
    }

    return PlanTimeline(
      items: items,
      changedIds: changedIds,
      onTapItem: onTapItem,
      onAddAt: onAddAt,
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
