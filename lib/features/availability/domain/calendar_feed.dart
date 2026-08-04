import 'package:flutter/foundation.dart';

/// A subscribed iCal link, as the client is allowed to see it.
///
/// Note what is missing: the URL. It is a bearer credential — anyone holding
/// it can read that calendar — so it is stored encrypted with a key the
/// database does not have, and never handed back. The user pasted it; if they
/// lose it, their calendar will issue another in less time than a "reveal"
/// button would take to build.
@immutable
class CalendarFeed {
  const CalendarFeed({
    required this.id,
    required this.label,
    required this.host,
    this.lastSyncedAt,
    this.lastError,
  });

  final String id;

  /// What the user called it.
  final String label;

  /// Host only, for display. The path is the secret.
  final String host;

  final DateTime? lastSyncedAt;

  /// The provider's own words when a fetch failed. "404" and "revoked" call
  /// for different reactions, so they are not flattened into one message.
  final String? lastError;

  bool get isHealthy => lastError == null && lastSyncedAt != null;

  static CalendarFeed fromRow(Map<String, dynamic> r) => CalendarFeed(
        id: r['id'] as String,
        label: r['label'] as String,
        host: r['host'] as String,
        lastSyncedAt: r['last_synced_at'] == null
            ? null
            : DateTime.parse(r['last_synced_at'] as String).toLocal(),
        lastError: r['last_error'] as String?,
      );
}
