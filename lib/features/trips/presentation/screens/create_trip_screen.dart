import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../domain/trip.dart';
import '../../domain/trip_draft.dart';
import '../controllers/trips_controller.dart';
import '../widgets/trip_form_fields.dart';

/// One scrolling form, not the three-step wizard in architecture section 4.
///
/// Deliberate deviation: the fields have good defaults and a wizard would turn
/// one scroll into three screens, which contradicts the product's first
/// principle. Pole samotná žijí v [TripFormFields], protože je editace
/// používá taky.
class CreateTripScreen extends ConsumerStatefulWidget {
  const CreateTripScreen({this.kind = TripKind.trip, super.key});

  final TripKind kind;

  @override
  ConsumerState<CreateTripScreen> createState() => _CreateTripScreenState();
}

class _CreateTripScreenState extends ConsumerState<CreateTripScreen> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _budget = TextEditingController();

  late final TripDraft _draft = TripDraft.blank(kind: widget.kind);

  @override
  void initState() {
    super.initState();
    // Bez setState. Jediné, co na názvu závisí, je tlačítko dole, a to
    // poslouchá controller přímo — přestavovat celý formulář na každé písmeno
    // je ta „Skipped frames" hláška z logu.
    _title.addListener(() => _draft.title = _title.text);
    _budget
        .addListener(() => _draft.budgetPerPerson = _parseMoney(_budget.text));
  }

  @override
  void dispose() {
    _title.dispose();
    _budget.dispose();
    super.dispose();
  }

  bool get _meeting => widget.kind == TripKind.meeting;

  Future<void> _submit() async {
    if (_draft.validationError != null) return;

    final String? id = await ref
        .read(createTripControllerProvider.notifier)
        .submit(_draft.toNewTrip());

    if (!mounted || id == null) return;
    // Straight into the new trip: the moment after creating is when the
    // organiser wants to share the link.
    context.pushReplacement(Routes.tripDetail(id));
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<void> state = ref.watch(createTripControllerProvider);

    ref.listen<AsyncValue<void>>(createTripControllerProvider,
        (AsyncValue<void>? _, AsyncValue<void> next) {
      if (!next.hasError) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(errorText(next.error!))));
    });

    return Scaffold(
      appBar: AppBar(title: Text(_meeting ? 'Nové setkání' : 'Nový výlet')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Sp.md),
          children: <Widget>[
            if (_meeting) ...<Widget>[
              Text(
                'Jen společný čas — žádné místo, doprava ani balení. '
                'Po založení pošlete odkaz a kalendáře udělají zbytek.',
                style: context.texts.bodyMedium
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              const SizedBox(height: Sp.lg),
            ],
            TripFormFields(
              draft: _draft,
              onChanged: () => setState(() {}),
              titleController: _title,
              budgetController: _budget,
            ),
            const SizedBox(height: Sp.xxl),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _title,
              builder: (BuildContext context, TextEditingValue _, Widget? __) {
                return PtButton(
                  label: 'Vytvořit a pozvat',
                  expand: true,
                  isLoading: state.isLoading,
                  onPressed: _draft.validationError == null ? _submit : null,
                );
              },
            ),
            const SizedBox(height: Sp.xl),
          ],
        ),
      ),
    );
  }
}

double? _parseMoney(String s) => double.tryParse(s.trim().replaceAll(',', '.'));
