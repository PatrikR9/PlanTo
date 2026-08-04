import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../error/error_text.dart';
import 'pt_states.dart';

/// The single rendering contract for async data (architecture section 7.4).
///
/// Every async surface renders exactly one of four states. Using this
/// everywhere is what stops loading and error handling drifting apart between
/// screens.
class AsyncValueView<T> extends StatelessWidget {
  const AsyncValueView({
    required this.value,
    required this.data,
    this.loading,
    this.onRetry,
    this.isEmpty,
    this.empty,
    super.key,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;

  /// Defaults to a skeleton, never a bare spinner on a content screen.
  final Widget Function()? loading;
  final VoidCallback? onRetry;

  /// Optional emptiness test — lists pass `(list) => list.isEmpty`.
  final bool Function(T data)? isEmpty;
  final Widget Function()? empty;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: true,
      loading: () => loading?.call() ?? const _DefaultSkeleton(),
      error: (Object error, StackTrace _) => PtErrorState(
        message: errorText(error),
        onRetry: onRetry,
      ),
      data: (T value) {
        if (isEmpty != null && isEmpty!(value)) {
          return empty?.call() ??
              const PtEmptyState(title: 'Zatím tu nic není');
        }
        return data(value);
      },
    );
  }
}

class _DefaultSkeleton extends StatelessWidget {
  const _DefaultSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PtSkeleton(height: 72),
          SizedBox(height: 12),
          PtSkeleton(height: 72),
          SizedBox(height: 12),
          PtSkeleton(height: 72),
        ],
      ),
    );
  }
}
