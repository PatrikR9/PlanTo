import 'package:flutter/foundation.dart';

import 'activity_tag.dart';

// Re-exported: ActivityTag moved into its own file when it grew from eight
// values to twenty-nine, but it is part of the trip's vocabulary and every
// caller holding a Trip wants it. Splitting the file should not mean editing
// five import lists.
export 'activity_tag.dart';

enum TripStatus { draft, planning, dateLocked, confirmed, completed, cancelled }

enum TransportPref { public, car, either }

/// How the trip is planned.
///
/// The day solver answers "which date suits everyone", which is right for a
/// weekend away and wrong for "kino ve čtvrtek" — for a two-hour thing the
/// answer is a start time, not a date. Both produce the same shape of
/// candidate ([start, end)), so everything downstream is shared.
enum TripGranularity {
  day('day'),
  time('time');

  const TripGranularity(this.wire);

  final String wire;

  static TripGranularity fromWire(String? v) =>
      v == 'time' ? TripGranularity.time : TripGranularity.day;
}

/// Minutes between proposed start times, in [TripGranularity.time].
///
/// 15 lets somebody say "17:45"; 60 keeps the list short. It is a real
/// trade-off, so it is the user's to make.
const List<int> kSlotSteps = <int>[15, 30, 45, 60];

/// Offered activity lengths, in minutes. Anything longer is a day trip and
/// should be planned as one.
const List<int> kSlotLengths = <int>[30, 45, 60, 90, 120, 180, 240, 360];

@immutable
class Trip {
  const Trip({
    required this.id,
    required this.title,
    required this.status,
    required this.originLabel,
    required this.originLat,
    required this.originLon,
    required this.windowStart,
    required this.windowEnd,
    required this.durationDays,
    required this.transport,
    required this.currency,
    required this.activityTags,
    required this.participantCount,
    required this.calendarSharedCount,
    required this.createdBy,
    required this.isOrganiser,
    required this.granularity,
    required this.slotStepMinutes,
    required this.dayStart,
    required this.dayEnd,
    this.slotMinutes,
    this.description,
    this.budgetPerPerson,
    this.earliestWake,
    this.originPlaceId,
    this.destinationId,
    this.destinationFree,
    this.destinationLat,
    this.destinationLon,
    this.destinationPlaceId,
    this.lockedStart,
    this.lockedEnd,
  });

  final String id;
  final String title;
  final String? description;
  final TripStatus status;
  final String originLabel;

  /// Kde se opravdu nastupuje. Od M7 to je konkrétní zastávka, ne střed
  /// města — a je to zároveň kotva pro řazení při výběru cíle.
  final double originLat;
  final double originLon;

  /// ID zastávky v `transit_places`. Null u výletů založených před M7 a u
  /// těch, kde místo mezitím z databáze zmizelo; [originLat]/[originLon]
  /// zůstávají platné vždycky, proto se geometrie čte z nich.
  final String? originPlaceId;

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

  /// Coordinates for [destinationFree]. Null means the group has named a
  /// place but nothing can be measured to it yet — a name is not a place.
  final double? destinationLat;
  final double? destinationLon;

  /// ID cílové zastávky. To, co se posílá vyhledávači spojení — jméno je pro
  /// člověka, ID pro MOTIS.
  final String? destinationPlaceId;

  final int participantCount;

  final TripGranularity granularity;

  /// How long the activity lasts. Null in day mode, where [durationDays] says
  /// it instead.
  final int? slotMinutes;
  final int slotStepMinutes;

  /// The usable part of a day. A board-game evening needs the window to reach
  /// 23:00; a sunrise hike needs 05:00. Hard-coding 07:00–21:00 was fine only
  /// while everything was a day trip.
  final Duration dayStart;
  final Duration dayEnd;

  /// How many participants have shared availability. Drives the single most
  /// important nudge in the product: "waiting on 2 people".
  final int calendarSharedCount;
  final String createdBy;

  /// Whether the current user is the organiser of THIS trip.
  ///
  /// Not `createdBy == myId`: the two can diverge (an organiser can be handed
  /// over) and the client should not be the place that decides who may lock a
  /// date. This mirrors trip_participants.role, and every organiser-only RPC
  /// re-checks it server-side regardless.
  final bool isOrganiser;

  /// Start of the locked slot. Null until the organiser locks.
  final DateTime? lockedStart;

  /// EXCLUSIVE end. In day mode the last day of the trip is lockedEnd minus a
  /// day; in time mode it is the moment the activity finishes. Named to make
  /// the off-by-one impossible to miss at the call site.
  final DateTime? lockedEnd;

  bool get isTimed => granularity == TripGranularity.time;
  bool get isDateLocked => lockedStart != null;

  Duration get slotDuration => Duration(minutes: slotMinutes ?? 120);

  bool get isDestinationDecided =>
      destinationId != null || (destinationFree?.isNotEmpty ?? false);

  /// Decided *and* locatable. The transport estimate needs the second half.
  bool get hasDestination =>
      isDestinationDecided && destinationLat != null && destinationLon != null;

  int get awaitingCalendarCount => participantCount - calendarSharedCount;

  /// Proposals only mean something once at least two people have shared.
  bool get canProposeDates => calendarSharedCount >= 2;
}
