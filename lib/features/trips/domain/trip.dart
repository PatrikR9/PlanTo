import 'package:flutter/foundation.dart';

enum TripStatus { draft, planning, dateLocked, confirmed, completed, cancelled }

enum TransportPref { public, car, either }

/// Activity tags. Kept as an enum rather than free strings so the planner and
/// the packing rules engine agree on a vocabulary — the rules in
/// `packing_rules.predicate` match on exactly these values.
enum ActivityTag { hiking, city, lake, castle, museum, cafe, festival, viewpoint }

@immutable
class Trip {
  const Trip({
    required this.id,
    required this.title,
    required this.status,
    required this.originLabel,
    required this.windowStart,
    required this.windowEnd,
    required this.durationDays,
    required this.transport,
    required this.currency,
    required this.activityTags,
    required this.participantCount,
    required this.calendarSharedCount,
    required this.createdBy,
    this.description,
    this.budgetPerPerson,
    this.earliestWake,
    this.destinationId,
    this.destinationFree,
  });

  final String id;
  final String title;
  final String? description;
  final TripStatus status;
  final String originLabel;
  final DateTime windowStart;
  final DateTime windowEnd;
  final int durationDays;
  final TransportPref transport;
  final double? budgetPerPerson;
  final String currency;
  final List<ActivityTag> activityTags;
  final Duration? earliestWake;
  final String? destinationId;
  final String? destinationFree;
  final int participantCount;

  /// How many participants have shared availability. Drives the single most
  /// important nudge in the product: "waiting on 2 people".
  final int calendarSharedCount;
  final String createdBy;

  bool get isDestinationDecided =>
      destinationId != null || (destinationFree?.isNotEmpty ?? false);

  int get awaitingCalendarCount => participantCount - calendarSharedCount;

  /// Proposals only mean something once at least two people have shared.
  bool get canProposeDates => calendarSharedCount >= 2;
}
