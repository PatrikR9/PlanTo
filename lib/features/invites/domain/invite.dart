import 'package:flutter/foundation.dart';

/// What an invitee sees before deciding to join. Deliberately thin: no
/// participant names, no coordinates, nothing that a link found in a group
/// chat should not reveal.
@immutable
class InvitePreview {
  const InvitePreview({
    required this.tripId,
    required this.title,
    required this.originLabel,
    required this.windowStart,
    required this.windowEnd,
    required this.durationMinutes,
    required this.participantCount,
    required this.organiserName,
    required this.alreadyMember,
    this.isMeeting = false,
  });

  final String tripId;

  /// Setkání se pozná i tady: náhled nemá co říct o odjezdu z místa, které
  /// neexistuje.
  final bool isMeeting;
  final String title;

  /// Prázdný u setkání.
  final String originLabel;
  final DateTime windowStart;
  final DateTime windowEnd;
  final int durationMinutes;
  final int participantCount;
  final String organiserName;
  final bool alreadyMember;
}

abstract interface class InviteRepository {
  /// Works signed out — that is the entire point of it.
  Future<InvitePreview?> preview(String token);

  /// Returns the trip id. Requires a session; the caller creates an anonymous
  /// one first if needed.
  Future<String> redeem(String token);

  Future<String> createLink(String tripId);
  Future<void> revokeLinks(String tripId);
}
