import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/error/failure.dart';
import '../../../auth/data/auth_repository_impl.dart';
import '../../../auth/domain/auth_repository.dart';

/// Who are you?
///
/// A guest arrives as "Cestovatel" — the fallback in handle_new_user, which
/// is all the database can invent when there is no email and no OAuth
/// profile. Three people called Cestovatel on a Dates tab is not a group
/// decision, it is a puzzle, and the organiser cannot nudge whoever is
/// missing if nobody has a name.
///
/// Asked here rather than at sign-in because this is the first moment the
/// answer is *used*, and because it is the same moment on both platforms:
/// the invitee who pastes an iCal link in a browser and the one who grants a
/// calendar permission on Android see exactly this screen first.
final FutureProvider<String?> myDisplayNameProvider =
    FutureProvider<String?>((Ref ref) {
  return ref.watch(authRepositoryProvider).myDisplayName();
});

/// True when we still do not know who this is.
bool needsName(String? name) =>
    name == null || name.trim().isEmpty || name == kAnonymousDisplayName;

class NameGate extends ConsumerStatefulWidget {
  const NameGate({required this.onDone, super.key});

  final VoidCallback onDone;

  @override
  ConsumerState<NameGate> createState() => _NameGateState();
}

class _NameGateState extends ConsumerState<NameGate> {
  final TextEditingController _name = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String value = _name.text.trim();
    if (value.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('Napište prosím jméno.')),
        );
      return;
    }

    setState(() => _saving = true);
    try {
      await ref.read(authRepositoryProvider).setDisplayName(value);
      ref.invalidate(myDisplayNameProvider);
      if (!mounted) return;
      widget.onDone();
    } on Failure catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(Sp.xl),
      children: <Widget>[
        const SizedBox(height: Sp.xxl),
        Text(
          'Jak vám mají říkat?',
          style: context.texts.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Sp.xs),
        Text(
          'Ostatní ve skupině uvidí jen tohle jméno — u kolika lidí zatím '
          'čekáme na odpověď, a u koho.',
          style: context.texts.bodyMedium
              ?.copyWith(color: context.colors.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Sp.xl),
        TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          // Jméno, ne esej. Bez stropu se do sloupce vejde cokoli a na
          // obrazovce s termíny to pak rozhodí každý řádek, kde se vypisuje.
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Jméno',
            hintText: 'Anna',
            counterText: '',
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: Sp.lg),

        // Překresluje se jen tlačítko, ne celá obrazovka.
        //
        // Předtím tu bylo `onChanged: (_) => setState(() {})`, takže každý
        // stisk klávesy přestavěl celý ListView — nadpis, odstavec, pole
        // i tlačítko. Na emulátoru se to pozná: písmena se opožďují za
        // psaním. Stav toho pole už jeden posluchač má, je jím sám
        // controller, a stačí poslouchat na jednom místě.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _name,
          builder: (BuildContext context, TextEditingValue value, _) {
            return PtButton(
              label: 'Pokračovat',
              expand: true,
              isLoading: _saving,
              // Tlačítko zůstává klikatelné i prázdné a chybu řekne až po
              // klepnutí. Zamknuté tlačítko sní první klepnutí bez jediné
              // odezvy a vypadá to, že aplikace zamrzla — což se stalo
              // i mně při testování.
              onPressed: _saving ? null : _save,
            );
          },
        ),
        const SizedBox(height: Sp.xs),
        Text(
          'Žádná registrace, žádný e-mail.',
          textAlign: TextAlign.center,
          style: context.texts.labelSmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ],
    );
  }
}
