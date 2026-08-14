import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../google_calendar_controller.dart';

/// Kam se člověk vrátí z obrazovky souhlasu Googlu.
///
/// Nemá být k vidění déle než vteřinu: vymění kód, načte obsazenost a jde dál.
/// Existuje proto, že návrat z cizí domény je nová instance aplikace — na webu
/// doslova — a stav rozdělané akce se přes něj nedá přenést jinak než URL.
class CalendarCallbackScreen extends ConsumerStatefulWidget {
  const CalendarCallbackScreen({
    required this.code,
    required this.tripId,
    this.error,
    super.key,
  });

  final String? code;
  final String? tripId;
  final String? error;

  @override
  ConsumerState<CalendarCallbackScreen> createState() =>
      _CalendarCallbackScreenState();
}

class _CalendarCallbackScreenState
    extends ConsumerState<CalendarCallbackScreen> {
  String? _failure;

  @override
  void initState() {
    super.initState();
    // Po prvním snímku, ne v initState: navigace i SnackBar potřebují strom,
    // který ještě neexistuje.
    WidgetsBinding.instance.addPostFrameCallback((_) => _finish());
  }

  Future<void> _finish() async {
    final String? code = widget.code;
    final String? tripId = widget.tripId;

    if (widget.error != null ||
        code == null ||
        code.isEmpty ||
        tripId == null) {
      setState(() {
        _failure = widget.error == 'access_denied'
            // Zrušení není chyba, je to odpověď. Hláška to nesmí obracet
            // v „něco se pokazilo", protože pak to člověk zkusí znovu místo
            // aby zadal dostupnost ručně.
            ? 'Připojení kalendáře jste zrušili.'
            : 'Z Googlu se nevrátil použitelný kód.';
      });
      return;
    }

    final bool ok = await ref
        .read(googleCalendarControllerProvider.notifier)
        .finish(tripId: tripId, code: code);

    if (!mounted) return;

    if (!ok) {
      final Object? err = ref.read(googleCalendarControllerProvider).error;
      setState(() => _failure = errorText(err ?? 'Nepodařilo se to.'));
      return;
    }

    // Rovnou na dostupnost, ne na přehled výletu. To, co po tomhle člověku
    // zbývá zkontrolovat, je právě tam — a stejné místo, kam vede připojení
    // kalendáře na Androidu.
    context.go(Routes.availability(tripId));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(Sp.xl),
            child: _failure == null
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      CircularProgressIndicator(),
                      SizedBox(height: Sp.md),
                      Text('Načítám obsazenost z kalendáře…'),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      PtEmptyState(
                        title: 'Kalendář se nepřipojil',
                        message: _failure!,
                        icon: Icons.event_busy_outlined,
                      ),
                      const SizedBox(height: Sp.md),
                      PtButton(
                        label: 'Zadat dostupnost jinak',
                        expand: true,
                        onPressed: widget.tripId == null
                            ? () => context.go(Routes.trips)
                            : () => context.go(Routes.availability(
                                  widget.tripId!,
                                )),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
