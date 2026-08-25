import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../transport/presentation/widgets/destination_card.dart';
import '../../domain/trip.dart';
import '../../domain/trip_draft.dart';
import '../controllers/trips_controller.dart';
import '../widgets/trip_form_fields.dart';

/// Přepsání toho, co se zadalo při zakládání.
///
/// Stejná pole jako zakládání, dvě věci navíc: posílá se jen rozdíl, a když se
/// změna dotkne termínů, řekne se předem, co se rozpadne. Server tu hlášku
/// nevrací — v tu chvíli už jsou hlasy smazané.
class EditTripScreen extends ConsumerWidget {
  const EditTripScreen({required this.tripId, super.key});

  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Trip> trip = ref.watch(tripProvider(tripId));

    return Scaffold(
      appBar: AppBar(title: const Text('Upravit')),
      body: AsyncValueView<Trip>(
        value: trip,
        onRetry: () => ref.invalidate(tripProvider(tripId)),
        // Klíč na id: kdyby se výlet mezitím přenačetl, formulář se má naplnit
        // znovu, ne si nechat rozpracovaný stav z předchozí verze.
        data: (Trip t) => _EditForm(key: ValueKey<String>(t.id), trip: t),
      ),
    );
  }
}

class _EditForm extends ConsumerStatefulWidget {
  const _EditForm({required this.trip, super.key});

  final Trip trip;

  @override
  ConsumerState<_EditForm> createState() => _EditFormState();
}

class _EditFormState extends ConsumerState<_EditForm> {
  late final TripDraft _draft = TripDraft.from(widget.trip);
  late final TextEditingController _title =
      TextEditingController(text: widget.trip.title);
  late final TextEditingController _budget = TextEditingController(
    text: widget.trip.budgetPerPerson == null
        ? ''
        : _money(widget.trip.budgetPerPerson!),
  );

  @override
  void initState() {
    super.initState();
    _title.addListener(() => _draft.title = _title.text);
    _budget.addListener(() {
      _draft.budgetPerPerson =
          double.tryParse(_budget.text.trim().replaceAll(',', '.'));
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _budget.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_draft.validationError != null) return;

    final Map<String, Object?> patch = _draft.patchFrom(widget.trip);
    if (patch.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    final List<String> warnings = _draft.warningsAgainst(widget.trip);
    if (warnings.isNotEmpty && !await _confirm(warnings)) return;

    final bool ok = await ref
        .read(updateTripControllerProvider.notifier)
        .submit(widget.trip.id, patch);

    if (!mounted || !ok) return;
    Navigator.of(context).pop();
  }

  Future<bool> _confirm(List<String> warnings) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Tahle změna něco přepíše'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final String w in warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: Sp.xs),
                child: Text('• $w'),
              ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Zpět'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Uložit'),
          ),
        ],
      ),
    );
    return yes ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<void> state = ref.watch(updateTripControllerProvider);

    ref.listen<AsyncValue<void>>(updateTripControllerProvider,
        (AsyncValue<void>? _, AsyncValue<void> next) {
      if (!next.hasError) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(errorText(next.error!))));
    });

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(Sp.md),
        children: <Widget>[
          TripFormFields(
            draft: _draft,
            onChanged: () => setState(() {}),
            titleController: _title,
            budgetController: _budget,
            // Cíl se neukládá s formulářem — má vlastní RPC, protože to není
            // volný text, ale konkrétní zastávka. Proto se uloží hned při
            // výběru a tlačítko „Uložit" se ho netýká.
            destinationField: DestinationCard(trip: widget.trip),
          ),
          const SizedBox(height: Sp.xxl),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _title,
            builder: (BuildContext context, TextEditingValue _, Widget? __) {
              return PtButton(
                label: 'Uložit',
                expand: true,
                isLoading: state.isLoading,
                onPressed: _draft.validationError == null ? _save : null,
              );
            },
          ),
          const SizedBox(height: Sp.xl),
        ],
      ),
    );
  }
}

/// `1200` místo `1200.0` — pole na peníze nemá ukazovat desetinnou nulu.
String _money(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
