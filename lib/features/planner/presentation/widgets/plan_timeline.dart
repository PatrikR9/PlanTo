import 'package:flutter/material.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/format/cs_format.dart';
import '../../domain/plan_item.dart';
import '../plan_strings.dart';

/// Svislá časová osa pobytu na místě.
///
/// Cesta tam a zpět na ní od M15 není — ty mají vlastní karty, protože
/// nástupiště a přestupy jsou detail, který se čte jinak než program dne.
/// Tady zůstalo to, co se opravdu plánuje: co se bude dělat a jak dlouho.
///
/// Mezery mezi položkami se **nevykreslují jako položky**. Volno není věc,
/// je to nepřítomnost věcí; kdyby mělo řádek v databázi, musel by ho engine
/// při každém posunu přepočítávat a uživatel by mazal prázdno.
class PlanTimeline extends StatelessWidget {
  const PlanTimeline({
    required this.items,
    required this.changedIds,
    required this.onTapItem,
    required this.onAddAt,
    super.key,
  });

  /// Položky jednoho úseku v chronologickém pořadí.
  final List<PlanItem> items;

  /// Co se posledním přepočtem pohnulo. Tichá změna je přesně to, co tenhle
  /// produkt dělat nesmí.
  final Set<String> changedIds;

  final void Function(PlanItem item) onTapItem;

  /// Přidání vlastního bodu do konkrétní mezery.
  final void Function(DateTime localStart, Duration length) onAddAt;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final List<Widget> rows = <Widget>[];

    for (int i = 0; i < items.length; i++) {
      final PlanItem item = items[i];

      rows.add(
        _TimelineRow(
          item: item,
          isFirst: i == 0,
          isLast: i == items.length - 1,
          isChanged: changedIds.contains(item.id),
          onTap: () => onTapItem(item),
        ),
      );

      // Mezera do dalšího bodu.
      if (i + 1 < items.length) {
        final PlanItem next = items[i + 1];
        final Duration gap = next.startsAt.difference(item.endsAt);
        if (gap.inMinutes >= 10) {
          rows.add(
            _GapRow(
              length: gap,
              onAdd: () => onAddAt(item.localEnd, gap),
            ),
          );
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.item,
    required this.isFirst,
    required this.isLast,
    required this.isChanged,
    required this.onTap,
  });

  final PlanItem item;
  final bool isFirst;
  final bool isLast;
  final bool isChanged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color accent = isChanged
        ? context.colors.primary
        : item.isLocked
            ? context.planto.availabilityFull
            : context.colors.outlineVariant;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 46,
            child: Padding(
              padding: const EdgeInsets.only(top: Sp.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    formatClock(item.localStart),
                    style: context.texts.labelLarge,
                  ),
                  Text(
                    formatClock(item.localEnd),
                    style: context.texts.labelSmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _Rail(isFirst: isFirst, isLast: isLast, accent: accent),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Sp.xs),
              child: _ItemCard(
                item: item,
                isChanged: isChanged,
                onTap: onTap,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Svislice s puntíkem. Nakreslená z Containerů, ne CustomPaintem: je to
/// čára a kolečko, a malovat je ručně by znamenalo řešit theme a tmavý režim
/// podruhé.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.isFirst,
    required this.isLast,
    required this.accent,
  });

  final bool isFirst;
  final bool isLast;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final Color line = context.planto.hairline;
    return SizedBox(
      width: 28,
      child: Column(
        children: <Widget>[
          SizedBox(
            height: Sp.md,
            child: Center(
              child: Container(
                width: 2,
                color: isFirst ? Colors.transparent : line,
              ),
            ),
          ),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Center(
              child: Container(
                width: 2,
                color: isLast ? Colors.transparent : line,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.isChanged,
    required this.onTap,
  });

  final PlanItem item;
  final bool isChanged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String? subtitle = planItemSubtitle(item);

    return Semantics(
      button: true,
      label: '${formatClock(item.localStart)} ${planItemTitle(item)}'
          '${item.isLocked ? ', zamčeno' : ''}'
          '${isChanged ? ', změněno' : ''}',
      child: PtCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.sm,
          vertical: Sp.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              planItemIcon(item),
              size: 20,
              color: context.colors.primary,
            ),
            const SizedBox(width: Sp.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    planItemTitle(item),
                    style: context.texts.bodyLarge,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: context.texts.labelSmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  if (item.costMin != null && item.costMax != null)
                    Text(
                      '≈ ${item.costMin!.round()}–${item.costMax!.round()} '
                      '${item.currency} · odhad',
                      style: context.texts.labelSmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  if (isChanged || item.userEdited)
                    Padding(
                      padding: const EdgeInsets.only(top: Sp.xxs),
                      child: Text(
                        isChanged ? 'Změněno přepočtem' : 'Upraveno ručně',
                        style: context.texts.labelSmall?.copyWith(
                          color: context.colors.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (item.isLocked)
              Icon(
                Icons.lock_outline,
                size: 16,
                color: context.planto.availabilityFull,
              ),
          ],
        ),
      ),
    );
  }
}

/// Volný čas mezi dvěma body. Není to položka plánu — je to nabídka nějakou
/// založit.
class _GapRow extends StatelessWidget {
  const _GapRow({required this.length, required this.onAdd});

  final Duration length;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 46, bottom: Sp.xs),
      child: Row(
        children: <Widget>[
          const SizedBox(width: 28),
          Text(
            '${formatLength(length.inMinutes)} volno',
            style: context.texts.labelSmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Sp.xs),
          PtButton(
            label: 'Přidat bod',
            variant: PtButtonVariant.text,
            icon: Icons.add,
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}
