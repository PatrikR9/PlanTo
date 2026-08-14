import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../trips/domain/trip.dart';
import '../../../transport/presentation/screens/plan_tab.dart';
import '../../data/cost_repository.dart';
import '../../domain/cost_line.dart';

/// The Costs tab: what one person pays, as a range.
///
/// A range everywhere, never a single number. The model behind it is fuel
/// prices, kilometric fare bands and a national food average — good enough to
/// decide with, nowhere near good enough to quote. "≈ 780–1 450 Kč" is a
/// useful sentence; "1 115 Kč" is a promise the app cannot keep, and the first
/// time it is wrong by 400 Kč the user stops believing the rest of the screen
/// too (architecture §1.5, honest confidence).
///
/// The unknown line is the important one. Accommodation is V1, so on a
/// two-day trip the total genuinely excludes the largest item in it. Showing
/// that total on its own would be the single most misleading number in the
/// product, so a partial estimate is labelled "od" and says what is missing.
class CostsTab extends ConsumerWidget {
  const CostsTab({required this.trip, super.key});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!trip.hasDestination) return _NoDestinationYet(trip: trip);

    final AsyncValue<CostEstimate> estimate =
        ref.watch(costEstimateProvider(trip.id));

    return AsyncValueView<CostEstimate>(
      value: estimate,
      onRetry: () => ref.invalidate(costEstimateProvider(trip.id)),
      isEmpty: (CostEstimate e) => e.isEmpty,
      empty: () => _NoDestinationYet(trip: trip),
      data: (CostEstimate e) => ListView(
        padding: const EdgeInsets.all(Sp.md),
        children: <Widget>[
          _TotalCard(estimate: e, trip: trip),
          const SizedBox(height: Sp.lg),
          Text('Z čeho se to skládá', style: context.texts.labelLarge),
          const SizedBox(height: Sp.xs),
          for (final CostLine l in e.lines) ...<Widget>[
            _LineCard(line: l, trip: trip),
            const SizedBox(height: Sp.xs),
          ],
          const SizedBox(height: Sp.sm),
          _Disclaimer(estimate: e),
        ],
      ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.estimate, required this.trip});

  final CostEstimate estimate;
  final Trip trip;

  @override
  Widget build(BuildContext context) {
    // "od" rather than "≈" when something has no number. The prefix is the
    // whole difference between an estimate and a floor, and it is one word.
    final String prefix = estimate.isPartial ? 'od ' : '≈ ';
    final double? budget = trip.budgetPerPerson;
    final bool overBudget = budget != null && estimate.totalMax > budget;

    return PtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Na osobu',
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Sp.xxs),
          Text(
            '$prefix${_czk(estimate.totalMin)}–${_czk(estimate.totalMax)} Kč',
            style: context.texts.headlineSmall,
          ),
          if (budget != null) ...<Widget>[
            const SizedBox(height: Sp.sm),
            Row(
              children: <Widget>[
                Icon(
                  overBudget ? Icons.error_outline : Icons.check_circle_outline,
                  size: 18,
                  color: overBudget
                      ? context.colors.error
                      : context.planto.availabilityFull,
                ),
                const SizedBox(width: Sp.xxs),
                Expanded(
                  child: Text(
                    overBudget
                        // Deliberately not "překročeno": the top of a range is
                        // the pessimistic end, and it has not happened yet.
                        ? 'Horní odhad je nad rozpočtem '
                            '${_czk(budget)} Kč'
                        : 'Vejde se do rozpočtu ${_czk(budget)} Kč',
                    style: context.texts.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({required this.line, required this.trip});

  final CostLine line;
  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final bool unknown = !line.hasNumbers;

    return PtCard(
      child: Row(
        children: <Widget>[
          Icon(
            _icon(line.kind),
            color: unknown
                ? context.colors.onSurfaceVariant
                : context.planto.availabilityFull,
          ),
          const SizedBox(width: Sp.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(_label(line.kind), style: context.texts.bodyLarge),
                Text(
                  _note(line, trip),
                  style: context.texts.labelSmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Text(
            unknown
                ? 'nevíme'
                : line.isFlat
                    ? '${_czk(line.minCzk!)} Kč'
                    : '${_czk(line.minCzk!)}–${_czk(line.maxCzk!)} Kč',
            style: context.texts.bodyLarge?.copyWith(
              color: unknown ? context.colors.onSurfaceVariant : null,
            ),
          ),
        ],
      ),
    );
  }

  static IconData _icon(CostKind k) => switch (k) {
        CostKind.transport => Icons.directions_transit_outlined,
        CostKind.entry => Icons.confirmation_number_outlined,
        CostKind.food => Icons.restaurant_outlined,
        CostKind.accommodation => Icons.hotel_outlined,
        CostKind.buffer => Icons.savings_outlined,
      };

  static String _label(CostKind k) => switch (k) {
        CostKind.transport => 'Doprava',
        CostKind.entry => 'Vstupné',
        CostKind.food => 'Jídlo',
        CostKind.accommodation => 'Nocleh',
        CostKind.buffer => 'Rezerva',
      };

  /// Every line says where its number came from. A user who disagrees with a
  /// figure can then argue with the right thing instead of with the app.
  static String _note(CostLine line, Trip trip) {
    final int days = trip.durationDays;
    return switch (line.kind) {
      CostKind.transport => 'tam a zpět, odhad ze vzdálenosti',
      CostKind.entry => 'podle údaje u cíle',
      CostKind.food => days > 1 ? 'průměr na den × $days dny' : 'průměr na den',
      CostKind.accommodation => 'zatím to neumíme spočítat',
      CostKind.buffer => 'na to, co model nezná',
    };
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer({required this.estimate});

  final CostEstimate estimate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Sp.sm),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: Radii.inputAll,
      ),
      child: Text(
        estimate.isPartial
            ? 'Součet je bez noclehu — ubytování zatím neplánujeme, takže '
                'skutečná částka bude vyšší. Ostatní položky jsou odhad z '
                'průměrných cen, ne konkrétní nabídka.'
            : 'Odhad z průměrných cen paliva, tarifů a útraty za jídlo. '
                'Konkrétní ceny se liší podle toho, kdy a kde nakoupíte.',
        style: context.texts.labelSmall,
      ),
    );
  }
}

class _NoDestinationYet extends ConsumerWidget {
  const _NoDestinationYet({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(Sp.xl),
      children: <Widget>[
        const SizedBox(height: Sp.xxl),
        PtEmptyState(
          title: 'Zatím není co počítat',
          message: trip.isOrganiser
              ? 'Vyberte cíl a spočítáme dopravu, jídlo i rezervu na osobu.'
              : 'Až organizátor vybere cíl, uvidíte tady odhad ceny na osobu.',
          icon: Icons.payments_outlined,
          actionLabel: trip.isOrganiser ? 'Vybrat cíl' : null,
          onAction: trip.isOrganiser
              ? () => pickDestination(context, ref, trip.id)
              : null,
        ),
      ],
    );
  }
}

/// Thousands separated by a non-breaking space, the Czech convention. `1 450`,
/// never `1,450` — a comma is the decimal mark here and reads as 1.45.
String _czk(double v) {
  final String s = v.round().toString();
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write('\u00A0');
    out.write(s[i]);
  }
  return out.toString();
}
