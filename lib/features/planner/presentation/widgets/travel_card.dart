import 'package:flutter/material.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/format/cs_format.dart';
import '../../domain/plan_item.dart';
import '../../domain/travel_outline.dart';
import '../plan_strings.dart';

/// Cesta tam (nebo zpět) na jeden řádek.
///
/// Na záložce Plán jsou tyhle dvě karty to hlavní. Celý průběh cesty —
/// nástupiště, přestupy, pěší přechody — je za klepnutím, ne pod ním: kdo
/// se dívá do plánu, řeší nejdřív „v kolik vyrážím", ne „kde přestupuju".
class TravelCard extends StatelessWidget {
  const TravelCard({
    required this.segment,
    required this.outline,
    required this.onTap,
    this.isChanged = false,
    super.key,
  });

  final PlanSegment segment;
  final TravelOutline outline;
  final VoidCallback onTap;

  /// Poslední přepočet s touhle cestou hnul. Tichá výměna spoje je přesně to,
  /// co se tady dít nesmí.
  final bool isChanged;

  @override
  Widget build(BuildContext context) {
    final DateTime? from = outline.localStart;
    final DateTime? to = outline.localEnd;

    return PtCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                segment == PlanSegment.homeward
                    ? Icons.keyboard_return
                    : Icons.trending_flat,
                size: 18,
                color: context.colors.primary,
              ),
              const SizedBox(width: Sp.xs),
              Expanded(
                child: Text(
                  planSegmentLabel(segment),
                  style: context.texts.labelLarge,
                ),
              ),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
          const SizedBox(height: Sp.xs),
          if (from == null || to == null)
            Text(
              'Spoj zatím nemáme.',
              style: context.texts.bodyMedium
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            )
          else ...<Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text(
                  '${formatClock(from)} → ${formatClock(to)}',
                  style: context.texts.headlineSmall,
                ),
                const Spacer(),
                if (outline.duration case final Duration d)
                  Text(
                    formatLength(d.inMinutes),
                    style: context.texts.bodyMedium
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
              ],
            ),
            if (outline.fromName case final String a)
              Text(
                '$a → ${outline.toName ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.texts.bodyMedium,
              ),
            const SizedBox(height: Sp.xxs),
            Text(
              _detail(outline),
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
          if (isChanged) ...<Widget>[
            const SizedBox(height: Sp.xxs),
            Text(
              'Změněno přepočtem',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.primary),
            ),
          ],
        ],
      ),
    );
  }

  /// Druhý řádek: kolik přestupů, kolik pěšky, kolik to stojí. Nula přestupů
  /// se píše slovem — „0 × přestup" nikdo neřekne.
  static String _detail(TravelOutline o) {
    return <String>[
      if (o.rides > 0)
        o.transfers == 0 ? 'bez přestupu' : '${o.transfers} × přestup',
      if (o.walkMinutes > 0) 'pěšky ${o.walkMinutes} min',
      if (o.costMin != null && o.costMax != null)
        '≈ ${o.costMin!.round()}–${o.costMax!.round()} ${o.currency} · odhad',
    ].join(' · ');
  }
}
