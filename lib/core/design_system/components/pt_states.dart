import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/tokens.dart';
import 'pt_button.dart';

/// Empty state. Always offers an action — an empty screen with no way forward
/// is a dead end (architecture section 7.4).
class PtEmptyState extends StatelessWidget {
  const PtEmptyState({
    required this.title,
    this.message,
    this.icon = Icons.explore_outlined,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String title;
  final String? message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: context.colors.onSurfaceVariant),
            const SizedBox(height: Sp.md),
            Text(
              title,
              style: context.texts.headlineSmall,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: Sp.xs),
              Text(
                message!,
                style: context.texts.bodyMedium
                    ?.copyWith(color: context.colors.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: Sp.xl),
              PtButton(label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      ),
    );
  }
}

/// Error state. Shows a human message and a retry — never a stack trace,
/// never the word "Exception".
class PtErrorState extends StatelessWidget {
  const PtErrorState({
    required this.message,
    this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: context.colors.error,
            ),
            const SizedBox(height: Sp.md),
            Text(
              message,
              style: context.texts.bodyLarge,
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: Sp.xl),
              PtButton(
                label: 'Zkusit znovu',
                variant: PtButtonVariant.tonal,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shimmer-free skeleton. A pulsing block is cheaper than a shimmer gradient
/// and reads as calmer, which suits the product.
class PtSkeleton extends StatefulWidget {
  const PtSkeleton({
    this.height = 16,
    this.width,
    this.borderRadius = Radii.inputAll,
    super.key,
  });

  final double height;
  final double? width;
  final BorderRadius borderRadius;

  @override
  State<PtSkeleton> createState() => _PtSkeletonState();
}

class _PtSkeletonState extends State<PtSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect Reduce Motion — a pulsing block is exactly what that setting
    // exists to stop (architecture section 7.6).
    final bool animate = !MediaQuery.disableAnimationsOf(context);

    return FadeTransition(
      opacity: animate
          ? Tween<double>(begin: 0.4, end: 0.8).animate(_controller)
          : const AlwaysStoppedAnimation<double>(0.6),
      child: Container(
        height: widget.height,
        width: widget.width,
        decoration: BoxDecoration(
          color: context.colors.surfaceContainerHighest,
          borderRadius: widget.borderRadius,
        ),
      ),
    );
  }
}
