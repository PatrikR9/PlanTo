import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/failure.dart';
import '../../../../app/env/env.dart';
import '../../../../app/router/routes.dart';
import '../../../../core/network/supabase_providers.dart';
import '../controllers/sign_in_controller.dart';

/// No Sign in with Apple: Guideline 4.8 applies to iOS apps only, and iOS is V2.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({this.from, super.key});

  /// Where the user was heading before the guard intercepted them.
  final String? from;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final TextEditingController _email = TextEditingController();
  bool _emailValid = false;

  /// Set once the mail is away. Drives the confirmation panel below, which
  /// replaces the form rather than pushing a route — the user has nothing to
  /// do here but read one sentence and go to their inbox.
  String? _sentTo;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  /// Last failure, kept on screen.
  ///
  /// A snackbar was the wrong choice here: it disappears after four seconds,
  /// and a sign-in that fails silently is indistinguishable from a button
  /// that does nothing. Auth errors stay visible until the next attempt.
  String? _error;

  /// Set when the address is already taken, so the banner can offer a way
  /// forward instead of just stating a problem.
  bool _emailTaken = false;
  bool _rateLimited = false;

  Future<void> _switchAccount() async {
    final String address = _email.text.trim();
    final bool ok = await ref
        .read(signInControllerProvider.notifier)
        .switchToExistingAccount(address);
    if (!mounted || !ok) return;
    setState(() {
      _emailTaken = false;
      _error = null;
      _sentTo = address;
    });
  }

  void _showError(Object error) {
    setState(() {
      _emailTaken = error is EmailAlreadyRegisteredFailure;
      _rateLimited = error is EmailRateLimitFailure;
      _error = switch (error) {
        final Failure f when kDebugMode => f.debugMessage,
        final Failure f => f.userMessage,
        _ => error.toString(),
      };
    });
  }

  Future<void> _sendCode() async {
    final SignInController c = ref.read(signInControllerProvider.notifier);
    final String address = _email.text.trim();
    final bool ok = await c.sendCode(address);
    if (!mounted || !ok) return;

    if (Env.emailUsesOtpCode) {
      unawaited(context.pushNamed(
        Routes.otpName,
        queryParameters: <String, String>{
          'email': address,
          if (widget.from != null) 'from': widget.from!,
        },
      ),);
    } else {
      // No custom SMTP yet, so what arrives is a link. Sending the user to a
      // code-entry screen with no code to enter is worse than useless.
      setState(() => _sentTo = address);
    }
  }

  /// Guests are signed in, so the router's "signed in → leave /auth" rule
  /// deliberately skips them (they must be able to reach this screen to
  /// upgrade). That means nothing moves them off it either, so the successful
  /// guest sign-in has to navigate on its own.
  Future<void> _continueAsGuest() async {
    final bool ok =
        await ref.read(signInControllerProvider.notifier).continueAsGuest();
    if (!mounted || !ok) return;
    context.go(widget.from ?? Routes.trips);
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<void> state = ref.watch(signInControllerProvider);
    final bool busy = state.isLoading;
    final bool isGuest = ref.watch(isAnonymousProvider);

    ref.listen<AsyncValue<void>>(signInControllerProvider,
        (AsyncValue<void>? _, AsyncValue<void> next) {
      if (next.hasError) {
        _showError(next.error!);
      } else if (next.isLoading && _error != null) {
        setState(() => _error = null);
      }
    });

    if (_sentTo != null) {
      return Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => setState(() => _sentTo = null)),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Sp.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(Icons.mark_email_read_outlined,
                    size: 48, color: context.colors.primary,),
                const SizedBox(height: Sp.md),
                Text('Zkontrolujte e-mail',
                    style: context.texts.titleLarge,
                    textAlign: TextAlign.center,),
                const SizedBox(height: Sp.xs),
                Text(
                  'Poslali jsme přihlašovací odkaz na $_sentTo.\n'
                  'Otevřete ho na tomhle zařízení a jste uvnitř.',
                  textAlign: TextAlign.center,
                  style: context.texts.bodyMedium
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
                const SizedBox(height: Sp.xl),
                PtButton(
                  label: 'Poslat znovu',
                  variant: PtButtonVariant.text,
                  onPressed: busy
                      ? null
                      : () => ref
                          .read(signInControllerProvider.notifier)
                          .sendCode(_sentTo!),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Sp.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: Sp.giant),
              Text('PlanTo', style: context.texts.displaySmall),
              const SizedBox(height: Sp.xs),
              Text(
                isGuest
                    ? 'Připojte si účet, ať o výlety nepřijdete.'
                    : 'Najdeme termín, který sedne všem.',
                style: context.texts.bodyLarge
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: Sp.lg),
                Container(
                  padding: const EdgeInsets.all(Sp.sm),
                  decoration: BoxDecoration(
                    color: context.colors.errorContainer,
                    borderRadius: Radii.inputAll,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(Icons.error_outline,
                          size: 18, color: context.colors.onErrorContainer,),
                      const SizedBox(width: Sp.xs),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              _error!,
                              style: context.texts.bodyMedium?.copyWith(
                                color: context.colors.onErrorContainer,
                              ),
                            ),
                            if (_rateLimited) ...<Widget>[
                              const SizedBox(height: Sp.xs),
                              Text(
                                'Vestavěný odesílatel Supabase zvládne '
                                '2 maily za hodinu pro celý projekt. '
                                'Na testování použijte hosta.',
                                style: context.texts.labelSmall?.copyWith(
                                  color: context.colors.onErrorContainer,
                                ),
                              ),
                            ],
                            if (_emailTaken) ...<Widget>[
                              const SizedBox(height: Sp.xs),
                              Text(
                                'Přihlaste se do něj. Výlety, do kterých jste '
                                'se připojili jako host, ale zůstanou u '
                                'hostovského účtu — sloučit je nejde.',
                                style: context.texts.labelSmall?.copyWith(
                                  color: context.colors.onErrorContainer,
                                ),
                              ),
                              const SizedBox(height: Sp.xs),
                              PtButton(
                                label: 'Přihlásit se do existujícího účtu',
                                variant: PtButtonVariant.tonal,
                                onPressed: busy ? null : _switchAccount,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Debug-only: turns "nothing happened" into a fact you can act
              // on. Stripped from release builds by the kDebugMode constant.
              if (kDebugMode) ...<Widget>[
                const SizedBox(height: Sp.sm),
                Text(
                  Env.isConfigured
                      ? 'backend: ${Uri.parse(Env.supabaseUrl).host}'
                      : 'backend: NENÍ NASTAVEN (chybí --dart-define-from-file)',
                  textAlign: TextAlign.center,
                  style: context.texts.labelSmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],

              const SizedBox(height: Sp.giant),

              // Hidden until an OAuth client exists in Google Cloud and the
              // provider is enabled in Supabase — see Env.googleEnabled.
              if (Env.googleEnabled) ...<Widget>[
                PtButton(
                  label: 'Pokračovat přes Google',
                  icon: Icons.account_circle_outlined,
                  expand: true,
                  isLoading: busy,
                  onPressed: () =>
                      ref.read(signInControllerProvider.notifier).google(),
                ),
                const SizedBox(height: Sp.xl),
                Row(
                  children: <Widget>[
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Sp.sm),
                      child: Text('nebo', style: context.texts.labelSmall),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: Sp.xl),
              ],

              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const <String>[AutofillHints.email],
                textInputAction: TextInputAction.done,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'E-mail',
                  hintText: 'jmeno@example.cz',
                ),
                onChanged: (String v) =>
                    setState(() => _emailValid = isPlausibleEmail(v)),
                onSubmitted: (_) => _emailValid ? _sendCode() : null,
              ),
              const SizedBox(height: Sp.sm),
              PtButton(
                label: Env.emailUsesOtpCode ? 'Poslat kód' : 'Poslat odkaz',
                variant: PtButtonVariant.tonal,
                expand: true,
                isLoading: busy,
                onPressed: _emailValid ? _sendCode : null,
              ),

              const SizedBox(height: Sp.lg),
              if (!isGuest)
                PtButton(
                  label: 'Pokračovat jako host',
                  variant: PtButtonVariant.text,
                  expand: true,
                  onPressed: busy ? null : _continueAsGuest,
                ),
              if (!isGuest)
                Text(
                  'Bez e-mailu. Účet si můžete připojit kdykoliv později '
                  'a o nic nepřijdete.',
                  textAlign: TextAlign.center,
                  style: context.texts.labelSmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),

              const SizedBox(height: Sp.xxl),
              Text(
                'Přihlášením souhlasíte s podmínkami použití '
                'a zpracováním údajů podle zásad ochrany soukromí.',
                textAlign: TextAlign.center,
                style: context.texts.labelSmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
