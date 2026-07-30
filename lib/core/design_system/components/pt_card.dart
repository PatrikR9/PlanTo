import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/tokens.dart';

/// Surface container. Depth comes from a tinted surface plus a hairline
/// border, not from a shadow (architecture section 7.1).
class PtCard extends StatelessWidget {
  const PtCard({
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(Sp.md),
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final Widget content = Padding(padding: padding, child: child);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerLow,
        borderRadius: Radii.cardAll,
        border: Border.all(color: context.planto.hairline),
      ),
      child: onTap == null
          ? content
          : Material(
              color: Colors.transparent,
              borderRadius: Radii.cardAll,
              child: InkWell(
                onTap: onTap,
                borderRadius: Radii.cardAll,
                child: content,
              ),
            ),
    );
  }
}
