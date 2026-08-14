import 'package:flutter/foundation.dart';

import 'activity_tag.dart';

// Re-exported: ActivityTag moved into its own file when it grew from eight
// values to twenty-nine, but it is part of the trip's vocabulary and every
// caller holding a Trip wants it. Splitting the file should not mean editing
// five import lists.
export 'activity_tag.dart';

enum TripStatus { draft, planning, dateLocked, confirmed, completed, cancelled }

enum TransportPref { public, car, either }

/// Co se vlastně plánuje.
///
/// Setkání je výlet, kterému chybí místo: stejné pozvánky, stejné sdílení
/// kalendáře, stejný solver i hlasování, ale bez cíle, dopravy, počasí,
/// nákladů a balení. Vlastní tabulka by tohle všechno zduplikovala.
enum TripKind {
  trip('trip'),
  meeting('meeting');

  const TripKind(this.wire);

  final String wire;

  static TripKind fromWire(String? v) =>
      v == 'meeting' ? TripKind.meeting : TripKind.trip;
}

/// How the trip is planned.
///
/// The day solver answers "which date suits everyone", which is right for a
/// weekend away and wrong for "kino ve čtvrtek" — for a two-hour thing the
/// answer is a start time, not a date. Both produce the same shape of
/// candidate ([start, end)), so everything downstream is shared.
///
/// Od M13 se nevybírá, odvozuje se z délky. Volba „celý den vs. pár hodin" je
/// otázka na implementaci, ne na záměr: kdo řekne „na tři hodiny", už tím
/// odpověděl.
enum TripGranularity { day, time }

/// Minutes between proposed start times, in [TripGranularity.time].
///
/// 15 lets somebody say "17:45"; 60 keeps the list short. It is a real
/// trade-off, so it is the user's to make.
const List<int> kSlotSteps = <int>[15, 30, 45, 60];

/// Hranice, pod kterou se hledá konkrétní čas a nad kterou celé dny. Je to
/// tentýž práh, jaký má trigger `trips_derive_duration()` v databázi — kdyby
/// se ta dvě čísla rozešla, klient by nabízel jiná pole, než jaká server
/// použije.
const int kDayMinutes = 1440;

/// Nejkratší a nejdelší výlet. Mirror `trips_duration_minutes_range`.
const int kMinDurationMinutes = 15;
const int kMaxDurationMinutes = 30 * kDayMinutes;

/// Nejdelší okno, ve kterém se dá hledat po slotech. Time mód vyrábí řádek na
/// (den × slot × účastník), takže rok při kroku 15 minut je 35 000 slotů.
const int kMaxTimeModeWindowDays = 42;

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
    required this.durationMinutes,
    required this.transport,
    required this.currency,
    required this.activityTags,
    required this.participantCount,
    required this.calendarSharedCount,
    required this.createdBy,
    required this.isOrganiser,
    required this.slotStepMinutes,
    required this.dayStart,
    required this.dayEnd,
    this.kind = TripKind.trip,
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
  final TripKind kind;
  final String title;
  final String? description;
  final TripStatus status;

  /// Prázdný u setkání — to nemá odkud vyjet. Server to drží checkem
  /// `trips_origin_required_for_trip`, ne nullable sloupcem, protože u výletu
  /// je původ pořád povinný.
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

  /// Jak dlouho výlet trvá. Od M13 jediný zdroj pravdy o délce — [durationDays],
  /// [granularity] i [slotMinutes] se z něj odvozují stejným pravidlem, jaké má
  /// trigger v databázi.
  final int durationMinutes;

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

  // --- odvozené z délky ------------------------------------------------------
  // Počítá se tady, ne v repository, aby to bylo jedno pravidlo místo dvou.
  // Server má tutéž trojici v triggeru; kdyby se rozešly, uživatel by viděl
  // jiný počet dní, než na jaký se plánuje.

  /// Kolik kalendářních dnů výlet zabere. `ceil`, ne zaokrouhlení: čtyřicet
  /// hodin jsou dva dny, ne den a půl.
  int get durationDays => (durationMinutes + kDayMinutes - 1) ~/ kDayMinutes;

  TripGranularity get granularity => durationMinutes < kDayMinutes
      ? TripGranularity.time
      : TripGranularity.day;

  /// Délka slotu. Null v denním módu, kde ji nemá co znamenat.
  int? get slotMinutes => isTimed ? durationMinutes : null;

  bool get isTimed => granularity == TripGranularity.time;
  bool get isMeeting => kind == TripKind.meeting;
  bool get isDateLocked => lockedStart != null;

  Duration get duration => Duration(minutes: durationMinutes);

  /// Fallback zůstává, aby žádná obrazovka nemusela null-checkovat délku,
  /// kterou stejně nikdy nezobrazí.
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
