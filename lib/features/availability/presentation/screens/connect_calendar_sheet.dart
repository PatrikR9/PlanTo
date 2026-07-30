import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/failure.dart';
import '../../data/device_calendar_source.dart';
import '../../domain/calendar_source.dart';
import '../availability_controller.dart';

/// Explain first, ask second.
///
/// The permission prompt is the single highest-risk moment in the product
/// (architecture section 22, risk 1). Android gives one sentence and a
/// yes/no; if the user says no permanently, the feature is gone. So the app
/// makes its case *before* the system dialog appears, and is specific about
/// what it does not read — vague reassurance reads as evasion.
class ConnectCalendarSheet extends ConsumerStatefulWidget {
  const ConnectCalendarSheet({
    required this.tripId,
    required this.windowStart,
    required this.windowEnd,
    super.key,
  });

  final String tripId;
  final DateTime windowStart;
  final DateTime windowEnd;

  static Future<void> show(
    BuildContext context, {
    required String tripId,
    required DateTime windowStart,
    required DateTime windowEnd,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ConnectCalendarSheet(
        tripId: tripId,
        windowStart: windowStart,
        windowEnd: windowEnd,
      ),
    );
  }

  @override
  ConsumerState<ConnectCalendarSheet> createState() =>
      _ConnectCalendarSheetState();
}

class _ConnectCalendarSheetState extends ConsumerState<ConnectCalendarSheet> {
  String? _error;

  Future<void> _connect() async {
    setState(() => _error = null);
    final bool ok =
        await ref.read(calendarSyncControllerProvider.notifier).sync(
              tripId: widget.tripId,
              windowStart: widget.windowStart,
              windowEnd: widget.windowEnd,
            );
    if (!mounted) return;

    if (ok) {
      Navigator.of(context).pop();
      return;
    }

    final Object? err = ref.read(calendarSyncControllerProvider).error;
    setState(() {
      _error = switch (err) {
        PermissionFailure(permission: 'calendar_permanent') =>
          'Přístup ke kalendáři jste zakázali natrvalo. '
              'Zapnout se dá v Nastavení → Aplikace → PlanTo → Oprávnění.',
        final Failure f => f.userMessage,
        _ => 'Nepodařilo se načíst kalendář.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final CalendarSource source = ref.watch(calendarSourceProvider);
    final bool busy = ref.watch(calendarSyncControllerProvider).isLoading;

    return Padding(
      padding: EdgeInsets.only(
        left: Sp.xl,
        right: Sp.xl,
        top: Sp.md,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Sp.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Sdílet dostupnost', style: context.texts.titleLarge),
          const SizedBox(height: Sp.xs),
          Text(
            'Abychom našli termín, který sedne všem, potřebujeme vědět, '
            'kdy máte zabráno — nic víc.',
            style: context.texts.bodyMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Sp.lg),
          const _Point(
            icon: Icons.check_circle_outline,
            good: true,
            text: 'Čteme jen začátky a konce zabraných bloků',
          ),
          const _Point(
            icon: Icons.check_circle_outline,
            good: true,
            text: 'Jen v rozmezí tohoto výletu, ne celý kalendář',
          ),
          const _Point(
            icon: Icons.block,
            good: false,
            text: 'Nečteme názvy událostí, místa ani účastníky',
          ),
          const _Point(
            icon: Icons.block,
            good: false,
            text:
                'Ostatní ve skupině vaše bloky nevidí — jen počet volných dnů',
          ),
          if (!source.isSupported) ...<Widget>[
            const SizedBox(height: Sp.lg),
            Container(
              padding: const EdgeInsets.all(Sp.sm),
              decoration: BoxDecoration(
                color: context.colors.surfaceContainerHighest,
                borderRadius: Radii.inputAll,
              ),
              child: Text(
                'Čtení kalendáře funguje zatím jen na Androidu. '
                'V prohlížeči si dostupnost zadáte ručně.',
                style: context.texts.labelSmall,
              ),
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: Sp.md),
            Container(
              padding: const EdgeInsets.all(Sp.sm),
              decoration: BoxDecoration(
                color: context.colors.errorContainer,
                borderRadius: Radii.inputAll,
              ),
              child: Text(
                _error!,
                style: context.texts.bodyMedium
                    ?.copyWith(color: context.colors.onErrorContainer),
              ),
            ),
          ],
          const SizedBox(height: Sp.xl),
          PtButton(
            label: 'Připojit kalendář',
            expand: true,
            isLoading: busy,
            onPressed: source.isSupported ? _connect : null,
          ),
          const SizedBox(height: Sp.xs),
          PtButton(
            // Closing lands back on the availability grid, which is where the
            // manual path already is. No dead end.
            label: 'Vyplním ručně',
            variant: PtButtonVariant.text,
            expand: true,
            onPressed: busy ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.good, required this.text});

  final IconData icon;
  final bool good;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            icon,
            size: 18,
            color: good
                ? context.planto.availabilityFull
                : context.colors.onSurfaceVariant,
          ),
          const SizedBox(width: Sp.xs),
          Expanded(child: Text(text, style: context.texts.bodyMedium)),
        ],
      ),
    );
  }
}
