import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/error/failure.dart';
import '../../data/invite_repository_impl.dart';

/// Creates a link and hands it over.
///
/// Uses the clipboard rather than the native share sheet on purpose for now:
/// `share_plus` would be one more dependency and one more thing that behaves
/// differently on web. Copy-to-clipboard works identically everywhere and is
/// two taps instead of one. Swap in the native sheet during the Android
/// polish pass — the link generation below does not change.
class ShareInviteSheet extends ConsumerStatefulWidget {
  const ShareInviteSheet({required this.tripId, super.key});

  final String tripId;

  static Future<void> show(BuildContext context, String tripId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ShareInviteSheet(tripId: tripId),
    );
  }

  @override
  ConsumerState<ShareInviteSheet> createState() => _ShareInviteSheetState();
}

class _ShareInviteSheetState extends ConsumerState<ShareInviteSheet> {
  String? _link;
  Object? _error;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _create();
  }

  Future<void> _create() async {
    try {
      final String link =
          await ref.read(inviteRepositoryProvider).createLink(widget.tripId);
      if (mounted) setState(() => _link = link);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _link!));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
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
          Text('Pozvěte ostatní', style: context.texts.titleLarge),
          const SizedBox(height: Sp.xs),
          Text(
            'Pošlete odkaz do skupiny. Kdo na něj klepne, připojí se '
            'bez registrace a rovnou sdílí dostupnost.',
            style: context.texts.bodyMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Sp.xl),
          if (_error != null)
            PtErrorState(
              message: _error is Failure
                  ? errorText(_error)
                  : Failure.genericMessage,
              onRetry: () {
                setState(() => _error = null);
                _create();
              },
            )
          else if (_link == null)
            const PtSkeleton(height: 56)
          else ...<Widget>[
            PtCard(
              child: SelectableText(
                _link!,
                style: context.texts.bodyMedium,
                maxLines: 2,
              ),
            ),
            const SizedBox(height: Sp.md),
            PtButton(
              label: _copied ? 'Zkopírováno' : 'Zkopírovat odkaz',
              icon: _copied ? Icons.check : Icons.copy,
              expand: true,
              onPressed: _copy,
            ),
            const SizedBox(height: Sp.xs),
            Text(
              'Odkaz platí 30 dní a dá se kdykoliv zrušit v nastavení výletu.',
              textAlign: TextAlign.center,
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
