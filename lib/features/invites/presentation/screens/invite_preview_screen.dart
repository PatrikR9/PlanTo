import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../app/router/routes.dart';
import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/network/supabase_providers.dart';
import '../../../auth/data/auth_repository_impl.dart';
import '../../data/invite_repository_impl.dart';
import '../../domain/invite.dart';

/// Rendered for signed-out users by design. This screen is the growth loop:
/// every guard, every paywall and every signup prompt is deliberately absent
/// until the person has seen what they were invited to.
class InvitePreviewScreen extends ConsumerStatefulWidget {
  const InvitePreviewScreen({required this.token, super.key});

  final String token;

  @override
  ConsumerState<InvitePreviewScreen> createState() =>
      _InvitePreviewScreenState();
}

class _InvitePreviewScreenState extends ConsumerState<InvitePreviewScreen> {
  bool _joining = false;

  Future<void> _join(InvitePreview preview) async {
    setState(() => _joining = true);
    try {
      // No session yet? Make an anonymous one. The invitee reaches "I'm in"
      // without ever seeing a signup form; the account can be upgraded later
      // in place, keeping the same user id.
      if (ref.read(sessionProvider) == null) {
        await ref.read(authRepositoryProvider).signInAnonymously();
      }
      final String tripId =
          await ref.read(inviteRepositoryProvider).redeem(widget.token);
      if (!mounted) return;

      // Straight to availability, not to the trip overview.
      //
      // Joining is not the thing the organiser needs from this person —
      // their availability is, and every extra screen between the tap and
      // that answer is where the funnel leaks. `go` builds the trip detail
      // underneath, so Back lands somewhere sensible rather than on a dead
      // invite page.
      context.go(Routes.availability(tripId));
    } catch (error) {
      if (!mounted) return;
      setState(() => _joining = false);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text(error is Failure
              ? error.userMessage
              : 'Pozvánka je neplatná nebo vypršela.',),
        ),);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<InvitePreview?> preview =
        ref.watch(invitePreviewProvider(widget.token));
    final DateFormat fmt = DateFormat('d. M.', 'cs');

    return Scaffold(
      body: SafeArea(
        child: AsyncValueView<InvitePreview?>(
          value: preview,
          onRetry: () => ref.invalidate(invitePreviewProvider(widget.token)),
          isEmpty: (InvitePreview? p) => p == null,
          empty: () => const PtEmptyState(
            title: 'Pozvánka nefunguje',
            message: 'Odkaz vypršel, byl zrušen, nebo je překlep v adrese.\n'
                'Zkuste si od organizátora nechat poslat nový.',
            icon: Icons.link_off,
          ),
          data: (InvitePreview? value) {
            final InvitePreview p = value!;
            return Padding(
              padding: const EdgeInsets.all(Sp.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Spacer(),
                  Text(
                    '${p.organiserName} vás zve',
                    style: context.texts.labelLarge
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: Sp.xs),
                  Text(
                    p.title,
                    style: context.texts.displaySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: Sp.xl),
                  PtCard(
                    child: Column(
                      children: <Widget>[
                        _Row(
                          icon: Icons.place_outlined,
                          label: 'Odjezd z',
                          value: p.originLabel,
                        ),
                        const SizedBox(height: Sp.sm),
                        _Row(
                          icon: Icons.date_range_outlined,
                          label: 'Kdy',
                          value: '${fmt.format(p.windowStart)} – '
                              '${fmt.format(p.windowEnd)}',
                        ),
                        const SizedBox(height: Sp.sm),
                        _Row(
                          icon: Icons.group_outlined,
                          label: 'Kdo',
                          value: '${p.participantCount} '
                              '${p.participantCount == 1 ? "člověk" : "lidí"}',
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (p.alreadyMember)
                    PtButton(
                      label: 'Otevřít výlet',
                      expand: true,
                      onPressed: () => context.go(Routes.tripDetail(p.tripId)),
                    )
                  else ...<Widget>[
                    PtButton(
                      label: 'Připojit se',
                      expand: true,
                      isLoading: _joining,
                      onPressed: () => _join(p),
                    ),
                    const SizedBox(height: Sp.xs),
                    Text(
                      'Bez registrace. Účet si můžete připojit později.',
                      textAlign: TextAlign.center,
                      style: context.texts.labelSmall
                          ?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: Sp.xl),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: context.colors.onSurfaceVariant),
        const SizedBox(width: Sp.sm),
        Text(
          label,
          style: context.texts.bodyMedium
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            style: context.texts.bodyLarge,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
