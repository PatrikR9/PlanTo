import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../data/availability_repository.dart';
import '../../domain/calendar_feed.dart';
import '../availability_controller.dart';

/// Subscribed calendars, and the way to add one.
///
/// The card is deliberately honest about the one thing that will bite people:
/// Google refreshes a private iCal feed slowly. Someone who adds a link,
/// changes their calendar and sees nothing move will conclude the app is
/// broken unless we said so first.
class CalendarFeedCard extends ConsumerWidget {
  const CalendarFeedCard({required this.tripId, super.key});

  final String tripId;

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    CalendarFeed feed,
  ) async {
    final bool ok = await ref
        .read(calendarFeedControllerProvider.notifier)
        .remove(feedId: feed.id, tripId: tripId);
    if (ok || !context.mounted) return;
    _showError(context, ref);
  }

  static void _showError(BuildContext context, WidgetRef ref) {
    final Object? error = ref.read(calendarFeedControllerProvider).error;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            errorText(error),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<CalendarFeed>> feeds = ref.watch(myFeedsProvider);
    final bool busy = ref.watch(calendarFeedControllerProvider).isLoading;
    final List<CalendarFeed> list = feeds.valueOrNull ?? const <CalendarFeed>[];

    return PtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.link, color: context.planto.availabilityFull),
              const SizedBox(width: Sp.sm),
              Expanded(
                child: Text(
                  'Odkaz na kalendář',
                  style: context.texts.labelLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.xxs),
          Text(
            list.isEmpty
                ? 'Funguje i v prohlížeči. Čteme jen obsazené časy, názvy '
                    'událostí ne — a odkaz si můžete kdykoliv zrušit ve '
                    'svém kalendáři.'
                : 'Aktualizuje se při každém otevření. Google svůj odkaz '
                    'obnovuje pomalu, klidně i jednou za den.',
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          for (final CalendarFeed f in list) ...<Widget>[
            const SizedBox(height: Sp.sm),
            _FeedRow(
              feed: f,
              onRemove: busy ? null : () => _remove(context, ref, f),
            ),
          ],
          const SizedBox(height: Sp.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: PtButton(
                  label: list.isEmpty ? 'Vložit odkaz' : 'Přidat další',
                  variant: PtButtonVariant.tonal,
                  icon: Icons.add_link,
                  expand: true,
                  onPressed: busy
                      ? null
                      : () => promptForCalendarFeed(context, ref, tripId),
                ),
              ),
              if (list.isNotEmpty) ...<Widget>[
                const SizedBox(width: Sp.xs),
                PtButton(
                  label: 'Načíst',
                  isLoading: busy,
                  onPressed: busy
                      ? null
                      : () async {
                          final bool ok = await ref
                              .read(calendarFeedControllerProvider.notifier)
                              .sync(tripId: tripId);
                          if (!ok && context.mounted) _showError(context, ref);
                        },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Ask for a link, then subscribe it.
///
/// Top-level rather than a method on the card because the chooser offers the
/// same thing before the card exists — in a browser this is the fast path,
/// not a fallback.
Future<bool> promptForCalendarFeed(
  BuildContext context,
  WidgetRef ref,
  String tripId,
) async {
  final _FeedInput? input = await showModalBottomSheet<_FeedInput>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _AddFeedSheet(),
  );
  if (input == null || !context.mounted) return false;

  final bool ok = await ref
      .read(calendarFeedControllerProvider.notifier)
      .sync(tripId: tripId, url: input.url, label: input.label);

  if (!ok && context.mounted) {
    final Object? error = ref.read(calendarFeedControllerProvider).error;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            errorText(error),
          ),
        ),
      );
  }
  return ok;
}

class _FeedRow extends StatelessWidget {
  const _FeedRow({required this.feed, required this.onRemove});

  final CalendarFeed feed;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final bool failed = feed.lastError != null;

    return Row(
      children: <Widget>[
        Icon(
          failed ? Icons.error_outline : Icons.check_circle_outline,
          size: 18,
          color:
              failed ? context.colors.error : context.planto.availabilityFull,
        ),
        const SizedBox(width: Sp.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(feed.label, style: context.texts.bodyMedium),
              Text(
                // The provider's own words, not ours. "404" and "this feed
                // was revoked" call for different reactions from the person
                // who pasted the link.
                failed
                    ? feed.lastError!
                    : feed.lastSyncedAt == null
                        ? feed.host
                        : 'Načteno ${_when(feed.lastSyncedAt!)}',
                style: context.texts.labelSmall?.copyWith(
                  color: failed
                      ? context.colors.error
                      : context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Odpojit',
          onPressed: onRemove,
        ),
      ],
    );
  }
}

String _when(DateTime t) => DateFormat('d. M. HH:mm', 'cs').format(t);

class _FeedInput {
  const _FeedInput(this.url, this.label);
  final String url;
  final String label;
}

class _AddFeedSheet extends StatefulWidget {
  const _AddFeedSheet();

  @override
  State<_AddFeedSheet> createState() => _AddFeedSheetState();
}

class _AddFeedSheetState extends State<_AddFeedSheet> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _label =
      TextEditingController(text: 'Můj kalendář');

  @override
  void dispose() {
    _url.dispose();
    _label.dispose();
    super.dispose();
  }

  bool get _valid => _url.text.trim().length > 12;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: Sp.xl,
        right: Sp.xl,
        top: Sp.md,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Sp.xl,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Odkaz na kalendář', style: context.texts.titleLarge),
            const SizedBox(height: Sp.xs),
            Text(
              'Najdete ho v nastavení svého kalendáře jako „tajná adresa ve '
              'formátu iCal“. Nikam se nepřihlašujete a heslo nikomu '
              'nedáváte.',
              style: context.texts.bodyMedium
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Sp.md),
            const _Where(
              app: 'Google Kalendář',
              steps: 'Nastavení → vyberte kalendář → Tajná adresa ve '
                  'formátu iCal',
            ),
            const _Where(
              app: 'Outlook',
              steps: 'Nastavení → Kalendář → Sdílené kalendáře → Publikovat '
                  'kalendář → ICS',
            ),
            const _Where(
              app: 'Apple Kalendář',
              steps: 'iCloud.com → Kalendář → ikona sdílení → Veřejný '
                  'kalendář',
            ),
            const SizedBox(height: Sp.md),
            TextField(
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Odkaz',
                hintText: 'https://calendar.google.com/calendar/ical/…',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Sp.sm),
            TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Název'),
            ),
            const SizedBox(height: Sp.md),
            Text(
              'Odkaz uložíme zašifrovaně a nikdy ho nikomu neukážeme, ani '
              'vám zpátky. Ostatní ve skupině uvidí jen počet volných lidí.',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Sp.lg),
            PtButton(
              label: 'Připojit',
              expand: true,
              onPressed: _valid
                  ? () => Navigator.of(context).pop(
                        _FeedInput(
                          _url.text.trim(),
                          _label.text.trim().isEmpty
                              ? 'Můj kalendář'
                              : _label.text.trim(),
                        ),
                      )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _Where extends StatelessWidget {
  const _Where({required this.app, required this.steps});

  final String app;
  final String steps;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(app, style: context.texts.labelMedium),
          Text(
            steps,
            style: context.texts.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
