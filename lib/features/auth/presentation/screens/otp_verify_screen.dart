import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../controllers/sign_in_controller.dart';

class OtpVerifyScreen extends ConsumerStatefulWidget {
  const OtpVerifyScreen({required this.email, this.from, super.key});

  final String email;
  final String? from;

  @override
  ConsumerState<OtpVerifyScreen> createState() => _OtpVerifyScreenState();
}

class _OtpVerifyScreenState extends ConsumerState<OtpVerifyScreen> {
  final TextEditingController _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final bool ok = await ref
        .read(signInControllerProvider.notifier)
        .verifyCode(email: widget.email, code: _code.text);
    if (!mounted || !ok) return;
    // Router redirect will not fire on its own here, because the user was
    // never redirected away from a guarded route — go explicitly.
    context.go(widget.from ?? Routes.trips);
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<void> state = ref.watch(signInControllerProvider);

    ref.listen<AsyncValue<void>>(signInControllerProvider,
        (AsyncValue<void>? _, AsyncValue<void> next) {
      if (!next.hasError) return;
      final Object e = next.error!;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(errorText(e)),
          ),
        );
    });

    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Sp.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('Zadejte kód', style: context.texts.titleLarge),
              const SizedBox(height: Sp.xs),
              Text(
                'Poslali jsme kód na ${widget.email}.',
                style: context.texts.bodyMedium
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              const SizedBox(height: Sp.sm),
              // Remove this once custom SMTP is configured and the template
              // uses {{ .Token }}.
              Text(
                'Pokud přišel odkaz místo kódu, stačí na něj klepnout — '
                'přihlásí vás rovnou.',
                style: context.texts.labelSmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              const SizedBox(height: Sp.xxl),
              TextField(
                controller: _code,
                autofocus: true,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: 6,
                enabled: !state.isLoading,
                style: context.texts.displaySmall?.copyWith(letterSpacing: 8),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: const InputDecoration(counterText: ''),
                onChanged: (String v) {
                  // Submit on the sixth digit — nobody wants to reach for a
                  // button after typing a code.
                  if (v.length == 6) _verify();
                },
              ),
              const SizedBox(height: Sp.md),
              PtButton(
                label: 'Ověřit',
                expand: true,
                isLoading: state.isLoading,
                onPressed: _code.text.length == 6 ? _verify : null,
              ),
              const SizedBox(height: Sp.sm),
              PtButton(
                label: 'Poslat kód znovu',
                variant: PtButtonVariant.text,
                expand: true,
                onPressed: state.isLoading
                    ? null
                    : () => ref
                        .read(signInControllerProvider.notifier)
                        .sendCode(widget.email),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
