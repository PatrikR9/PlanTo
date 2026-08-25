import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../trips/domain/trip.dart';
import '../../domain/packing_item.dart';
import '../packing_controller.dart';

/// The Packing tab: a checklist that says why.
///
/// Rules, not a model. "Prší v sobotu odpoledne, vezmi pláštěnku" has to come
/// out the same every time, be testable, and cost nothing — that is the
/// definition of a rule. AI adds the things the rules do not know about, and
/// that is the paid layer (§11.2); nothing a free user can reach touches an
/// LLM.
///
/// Every row carries its cause. A list with no reasons is one you cannot argue
/// with: you cannot tell whether the raincoat is there because of the forecast
/// or because the app always says raincoat, so you either carry it forever or
/// stop reading. The reason is what makes it worth the space this once.
class PackingTab extends ConsumerWidget {
  const PackingTab({required this.trip, super.key});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<PackingItem>> items =
        ref.watch(packingControllerProvider(trip.id));

    ref.listen<Object?>(packingErrorProvider, (Object? _, Object? e) {
      if (e == null) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(errorText(e))));
      ref.read(packingErrorProvider.notifier).state = null;
    });

    return AsyncValueView<List<PackingItem>>(
      value: items,
      onRetry: () => ref.invalidate(packingControllerProvider(trip.id)),
      isEmpty: (List<PackingItem> l) => l.isEmpty,
      empty: () => const _Empty(),
      data: (List<PackingItem> list) => _List(trip: trip, items: list),
    );
  }
}

class _List extends ConsumerWidget {
  const _List({required this.trip, required this.items});

  final Trip trip;
  final List<PackingItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int done = items.where((PackingItem i) => i.checked).length;
    final bool anyWeather = items.any((PackingItem i) => i.weatherBased);

    return ListView(
      padding: const EdgeInsets.all(Sp.md),
      children: <Widget>[
        _Progress(done: done, total: items.length),
        const SizedBox(height: Sp.md),
        for (final PackingCategory c in PackingCategory.values)
          if (items.any((PackingItem i) => i.category == c)) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.xxs, Sp.sm, 0, Sp.xs),
              child: Text(c.label, style: context.texts.labelLarge),
            ),
            PtCard(
              child: Column(
                children: <Widget>[
                  for (final PackingItem i
                      in items.where((PackingItem i) => i.category == c))
                    _Row(item: i, tripId: trip.id),
                ],
              ),
            ),
          ],
        if (anyWeather) ...<Widget>[
          const SizedBox(height: Sp.md),
          Container(
            padding: const EdgeInsets.all(Sp.sm),
            decoration: BoxDecoration(
              color: context.colors.surfaceContainerHighest,
              borderRadius: Radii.inputAll,
            ),
            child: Text(
              // Said before it happens, not after. A list that quietly loses
              // four items when the group re-votes reads as a bug.
              trip.isDateLocked
                  ? 'Část seznamu vychází z předpovědi na vybraný termín. '
                      'Když se předpověď změní, změní se i seznam.'
                  : 'Termín ještě není vybraný, takže počasí je z nejlepšího '
                      'návrhu. Po výběru se seznam přepočítá.',
              style: context.texts.labelSmall,
            ),
          ),
        ],
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final bool complete = done == total && total > 0;

    return PtCard(
      child: Row(
        children: <Widget>[
          Icon(
            complete ? Icons.check_circle : Icons.luggage_outlined,
            color: complete
                ? context.planto.availabilityFull
                : context.colors.onSurfaceVariant,
          ),
          const SizedBox(width: Sp.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  complete ? 'Sbaleno' : 'Sbaleno $done z $total',
                  style: context.texts.titleMedium,
                ),
                const SizedBox(height: Sp.xxs),
                ClipRRect(
                  borderRadius: Radii.inputAll,
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : done / total,
                    minHeight: 6,
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

class _Row extends ConsumerWidget {
  const _Row({required this.item, required this.tripId});

  final PackingItem item;
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Color subdued = context.colors.onSurfaceVariant;

    return Semantics(
      // The whole row is one control. Two adjacent tap targets — the checkbox
      // and the label — is exactly the kind of thing that fails at 48 dp with
      // cold hands.
      checked: item.checked,
      label: '${item.label}, ${item.reason}',
      child: InkWell(
        onTap: () =>
            ref.read(packingControllerProvider(tripId).notifier).toggle(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.xxs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ExcludeSemantics(
                child: Checkbox(
                  value: item.checked,
                  onChanged: (_) => ref
                      .read(packingControllerProvider(tripId).notifier)
                      .toggle(item),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              item.label,
                              style: context.texts.bodyLarge?.copyWith(
                                decoration: item.checked
                                    ? TextDecoration.lineThrough
                                    : null,
                                color: item.checked ? subdued : null,
                              ),
                            ),
                          ),
                          // Colour is never the only signal (§7.6): essentials
                          // carry a word as well as a tint.
                          if (item.isEssential && !item.checked) ...<Widget>[
                            const SizedBox(width: Sp.xs),
                            Text(
                              'nutné',
                              style: context.texts.labelSmall
                                  ?.copyWith(color: context.colors.error),
                            ),
                          ],
                        ],
                      ),
                      if (item.reason.isNotEmpty)
                        Text(
                          item.reason,
                          style: context.texts.labelSmall
                              ?.copyWith(color: subdued),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: Sp.xs),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(Sp.xl),
      children: const <Widget>[
        SizedBox(height: Sp.xxl),
        PtEmptyState(
          title: 'Zatím není co balit',
          message: 'Vyberte, co chcete dělat, a seznam se sestaví sám — '
              'podle aktivit, počasí a délky výletu.',
          icon: Icons.luggage_outlined,
        ),
      ],
    );
  }
}
