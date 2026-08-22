import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/env/env.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/error/failure.dart';
import '../../../trips/domain/trip.dart';
import '../../data/device_calendar_source.dart';
import '../../data/google_calendar_repository.dart';
import '../../domain/calendar_source.dart';
import '../../domain/google_calendar.dart';
import '../availability_controller.dart';
import '../google_calendar_controller.dart';

/// The first thing an invitee sees, and for most of them the last.
///
/// This used to be a grid with a "connect calendar" card above it and an
/// explain-first sheet behind that — three surfaces to cross before the app
/// had the one thing it asked them for. Now the explanation IS the screen and
/// the button underneath it goes straight to the permission prompt: tap,
/// allow, done, screen closes.
///
/// The explaining is not padding. The permission prompt is the highest-risk
/// moment in the product (architecture section 22, risk 1): Android gives one
/// sentence and a yes/no, and a permanent "no" removes the feature for good.
/// Being specific about what we do *not* read is the whole argument, and
/// vague reassurance reads as evasion.
class AvailabilityChooser extends ConsumerStatefulWidget {
  const AvailabilityChooser({
    required this.trip,
    required this.onManual,
    required this.onLink,
    required this.onConnected,
    super.key,
  });

  final Trip trip;

  /// "I'll type it in" — reveals the grid.
  final VoidCallback onManual;

  /// "Paste a link" — the path that works in a browser.
  final VoidCallback onLink;

  /// The device calendar landed and is already saved server-side.
  final VoidCallback onConnected;

  @override
  ConsumerState<AvailabilityChooser> createState() =>
      _AvailabilityChooserState();
}

class _AvailabilityChooserState extends ConsumerState<AvailabilityChooser> {
  String? _error;

  Future<void> _connect() async {
    setState(() => _error = null);

    final bool ok =
        await ref.read(calendarSyncControllerProvider.notifier).sync(
              tripId: widget.trip.id,
              windowStart: widget.trip.windowStart,
              windowEnd: widget.trip.windowEnd,
            );

    if (!mounted) return;
    if (ok) {
      // Already written to the server by the controller. Asking them to press
      // "save" afterwards would imply it had not been.
      widget.onConnected();
      return;
    }

    final Object? err = ref.read(calendarSyncControllerProvider).error;
    setState(() {
      _error = switch (err) {
        // "Aplikace nemá potřebné oprávnění" is true and useless: on a
        // permanent denial the only way back is Settings, so say that.
        PermissionFailure(permission: 'calendar_permanent') =>
          'Přístup ke kalendáři jste zakázali natrvalo. Zapnout se dá '
              'v Nastavení → Aplikace → PlanTo → Oprávnění. Nebo to zadejte '
              'ručně, je to na pár klepnutí.',
        final Failure f => errorText(f),
        _ => 'Nepodařilo se načíst kalendář.',
      };
    });
  }

  /// Odchod na obrazovku souhlasu Googlu. Vrací se přes docs/oauth.html na
  /// routu `/calendar-callback`, takže tady se na nic nečeká — selhat může
  /// jen samotné otevření prohlížeče, a to je jediné, co jde říct hned.
  Future<void> _connectGoogle() async {
    setState(() => _error = null);

    // Rozbité nastavení se pozná tady, ne na chybové stránce Googlu. Tam už
    // je člověk mimo aplikaci, mimo výlet a bez jediné věty, která by mu
    // řekla, co má dělat dál.
    if (!Env.googleCalendarClientIdLooksValid) {
      setState(() {
        _error = 'Připojení Googlem není v této verzi aplikace správně '
            'nastavené. Dostupnost zatím zadejte ručně nebo odkazem na '
            'kalendář — na výsledku to nic nemění.';
      });
      return;
    }

    final bool opened = await ref
        .read(googleCalendarControllerProvider.notifier)
        .connect(widget.trip.id);
    if (!mounted || opened) return;
    setState(() => _error = 'Nepodařilo se otevřít přihlášení ke Googlu.');
  }

  @override
  Widget build(BuildContext context) {
    final CalendarSource source = ref.watch(calendarSourceProvider);
    final bool busy = ref.watch(calendarSyncControllerProvider).isLoading;
    final bool connecting =
        ref.watch(googleCalendarControllerProvider).isLoading;

    // Připojený účet Googlu. Kvůli jediné, ale podstatné větě — viz níž.
    final GoogleAccount? google = ref.watch(googleAccountProvider).valueOrNull;

    return ListView(
      padding: const EdgeInsets.all(Sp.xl),
      children: <Widget>[
        const SizedBox(height: Sp.md),

        // Prázdný kalendář je odpověď, ne selhání — a bez tohohle řádku
        // vypadal úplně stejně jako rozbité připojení.
        //
        // Obrazovka dostupnosti se řídí `_blocks.isNotEmpty`, takže úspěšné
        // načtení, které nenašlo žádnou obsazenost, skončí zpátky na tomhle
        // rozcestníku — se stejným tlačítkem, jako by se nestalo nic. Server
        // přitom už zapsal `calendar_shared = true` a skupina čeká zbytečně.
        // Stálo to jedno odpoledne hledání chyby, která tam nebyla.
        if (google != null) ...<Widget>[
          PtCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.check_circle_outline,
                  color: context.colors.primary,
                  size: 20,
                ),
                const SizedBox(width: Sp.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        google.email == null
                            ? 'Kalendář Googlem je připojený'
                            : 'Připojeno jako ${google.email}',
                        style: context.texts.titleSmall,
                      ),
                      const SizedBox(height: Sp.xs),
                      Text(
                        'V rozmezí tohohle výletu v něm nemáte nic '
                        'zabraného, takže vás ostatní vidí jako volného. '
                        'Pokud to nesedí, obsazenost bývá v jiném než '
                        'hlavním kalendáři — ten se přes Google nečte. '
                        'Použijte odkaz na kalendář nebo ji zadejte ručně.',
                        style: context.texts.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Sp.xl),
        ],

        Text(
          'Kdy máte čas?',
          style: context.texts.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Sp.xs),
        Text(
          'Abychom našli termín, který sedne všem, potřebujeme vědět, kdy '
          'máte zabráno — nic víc.',
          style: context.texts.bodyMedium
              ?.copyWith(color: context.colors.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Sp.xl),

        const _Point(
          good: true,
          text: 'Čteme jen začátky a konce zabraných bloků',
        ),
        const _Point(
          good: true,
          text: 'Jen v rozmezí tohohle výletu, ne celý kalendář',
        ),
        const _Point(
          good: false,
          text: 'Nečteme názvy událostí, místa ani účastníky',
        ),
        const _Point(
          good: false,
          text: 'Ostatní vaše bloky nevidí — jen počet volných lidí',
        ),

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

        // One tap. On Android this opens the OS prompt directly; there is no
        // intermediate sheet left to cross.
        if (source.isSupported)
          PtButton(
            label: 'Připojit kalendář',
            icon: Icons.event_available,
            expand: true,
            isLoading: busy,
            onPressed: _connect,
          )
        // V prohlížeči žádné API ke kalendáři v zařízení není, takže tam je
        // Google to nejbližší jednomu klepnutí. Scope vrací jen obsazenost,
        // takže slib o čtení nadpisů platí i tady.
        else if (Env.googleCalendarEnabled)
          PtButton(
            label: 'Připojit kalendář Googlem',
            icon: Icons.event_available,
            expand: true,
            isLoading: connecting,
            onPressed: connecting ? null : _connectGoogle,
          )
        else
          PtButton(
            // Bez OAuth klienta zbývá odkaz. Skryté tlačítko je lepší než
            // tlačítko, které skončí na chybové stránce Googlu.
            label: 'Vložit odkaz na kalendář',
            icon: Icons.add_link,
            expand: true,
            onPressed: busy ? null : widget.onLink,
          ),

        const SizedBox(height: Sp.xs),
        // Na Androidu je Google druhá cesta, ne první: systémový kalendář už
        // ty účty obsahuje a nechce po nikom cizí přihlášení.
        if (source.isSupported && Env.googleCalendarEnabled)
          PtButton(
            label: 'Připojit Googlem',
            variant: PtButtonVariant.text,
            expand: true,
            onPressed: connecting ? null : _connectGoogle,
          ),
        if (source.isSupported || Env.googleCalendarEnabled)
          PtButton(
            label: 'Mám odkaz na kalendář',
            variant: PtButtonVariant.text,
            expand: true,
            onPressed: busy ? null : widget.onLink,
          ),
        PtButton(
          label: 'Radši zadám ručně',
          variant: PtButtonVariant.text,
          expand: true,
          onPressed: busy ? null : widget.onManual,
        ),
      ],
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.good, required this.text});

  final bool good;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            good ? Icons.check_circle_outline : Icons.block,
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
