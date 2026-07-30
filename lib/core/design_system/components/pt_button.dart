import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/tokens.dart';

enum PtButtonVariant { filled, tonal, text, destructive }

/// The only button in the app. Handles its own loading state so callers never
/// swap a button for a spinner (which causes layout jumps).
class PtButton extends StatelessWidget {
  const PtButton({
    required this.label,
    required this.onPressed,
    this.variant = PtButtonVariant.filled,
    this.icon,
    this.isLoading = false,
    this.expand = false,
    super.key,
  });

  final String label;

  /// Null disables the button. Combined with [isLoading] this gives the four
  /// states every button needs: idle, pressed, loading, disabled.
  final VoidCallback? onPressed;
  final PtButtonVariant variant;
  final IconData? icon;
  final bool isLoading;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null && !isLoading;

    final Widget child = isLoading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 18),
                const SizedBox(width: Sp.xs),
              ],
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            ],
          );

    final Widget button = switch (variant) {
      PtButtonVariant.filled => FilledButton(
          onPressed: enabled ? onPressed : null,
          child: child,
        ),
      PtButtonVariant.tonal => FilledButton.tonal(
          onPressed: enabled ? onPressed : null,
          child: child,
        ),
      PtButtonVariant.text => TextButton(
          onPressed: enabled ? onPressed : null,
          child: child,
        ),
      PtButtonVariant.destructive => FilledButton(
          onPressed: enabled ? onPressed : null,
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.errorContainer,
            foregroundColor: context.colors.onErrorContainer,
          ),
          child: child,
        ),
    };

    return Semantics(
      button: true,
      enabled: enabled,
      label: isLoading ? '$label — načítá se' : label,
      child: expand ? SizedBox(width: double.infinity, child: button) : button,
    );
  }
}
