import '../../../core/format/cs_format.dart';
import 'trip.dart';
import 'trip_repository.dart';

/// Co formulář výletu edituje — zakládání i editace.
///
/// Existuje proto, aby ta dvě použití sdílela jedna pole. [NewTrip] popisuje
/// výlet, který ještě nemá id, a patch popisuje rozdíl; kdyby si obrazovky
/// držely stav samy, byly by to dvě sady polí, které se rozejdou při prvním
/// přidaném řádku.
///
/// Mutable schválně: je to stav jednoho formuláře, ne hodnota, která se
/// předává dál.
class TripDraft {
  TripDraft.blank({this.kind = TripKind.trip})
      : title = '',
        description = null,
        originLabel = null,
        originLat = null,
        originLon = null,
        originPlaceId = null,
        windowStart = null,
        windowEnd = null,
        durationMinutes = kind == TripKind.meeting ? 60 : kDayMinutes,
        transport = TransportPref.either,
        budgetPerPerson = null,
        activityTags = <ActivityTag>{},
        slotStepMinutes = 30,
        dayStart = const Duration(hours: 7),
        dayEnd = const Duration(hours: 21);

  TripDraft.from(Trip t)
      : kind = t.kind,
        title = t.title,
        description = t.description,
        originLabel = t.originLabel.isEmpty ? null : t.originLabel,
        originLat = t.originLat,
        originLon = t.originLon,
        originPlaceId = t.originPlaceId,
        windowStart = t.windowStart,
        // Databáze drží konec jako exkluzivní, picker jako poslední den. Draft
        // používá tvar pickeru a převádí ho zpátky až na hranici — jinak by se
        // okno při každém uložení posunulo o den.
        windowEnd = t.windowEnd.subtract(const Duration(days: 1)),
        durationMinutes = t.durationMinutes,
        transport = t.transport,
        budgetPerPerson = t.budgetPerPerson,
        activityTags = t.activityTags.toSet(),
        slotStepMinutes = t.slotStepMinutes,
        dayStart = t.dayStart,
        dayEnd = t.dayEnd;

  /// Neměnný po založení — server `update_trip` změnu druhu odmítne. Výlet,
  /// který se v půlce promění v setkání, by osiřel s cílem a dopravou.
  final TripKind kind;

  String title;
  String? description;
  String? originLabel;
  double? originLat;
  double? originLon;
  String? originPlaceId;
  DateTime? windowStart;
  DateTime? windowEnd;
  int durationMinutes;
  TransportPref transport;
  double? budgetPerPerson;
  Set<ActivityTag> activityTags;
  int slotStepMinutes;
  Duration dayStart;
  Duration dayEnd;

  bool get isMeeting => kind == TripKind.meeting;
  bool get isTimed => durationMinutes < kDayMinutes;

  /// Kolik dní okno pokrývá, včetně obou krajních.
  int get windowDays => windowStart == null || windowEnd == null
      ? 0
      : windowEnd!.difference(windowStart!).inDays + 1;

  /// Proč formulář nejde odeslat, nebo null. Vrací důvod, ne bool: tlačítko
  /// bez vysvětlení nechá člověka hádat, které pole mu chybí.
  ///
  /// Mirror serverových kontrol v `_assert_trip_window`. Duplicita je zde
  /// záměrná — server je ta skutečná obrana, tohle je jen slušnost.
  String? get validationError {
    if (title.trim().isEmpty) return 'Doplňte název.';
    if (!isMeeting && originLabel == null) return 'Vyberte, odkud jedete.';
    if (windowStart == null || windowEnd == null) {
      return 'Vyberte rozmezí, kdy by se to hodilo.';
    }
    if (durationMinutes < kMinDurationMinutes ||
        durationMinutes > kMaxDurationMinutes) {
      return 'Délka musí být mezi 15 minutami a 30 dny.';
    }
    if (isTimed && windowDays > kMaxTimeModeWindowDays) {
      return 'Na hodiny se dá plánovat nejvýš $kMaxTimeModeWindowDays dnů '
          'dopředu. Zkraťte rozmezí, nebo prodlužte délku na celé dny.';
    }
    if (!isTimed && _durationDays > windowDays) {
      return 'Výlet je delší než rozmezí, ve kterém ho hledáme.';
    }
    return null;
  }

  int get _durationDays => (durationMinutes + kDayMinutes - 1) ~/ kDayMinutes;

  NewTrip toNewTrip() => NewTrip(
        kind: kind,
        title: title.trim(),
        description: _blankToNull(description),
        originLabel: originLabel,
        originLat: originLat,
        originLon: originLon,
        originPlaceId: originPlaceId,
        windowStart: windowStart!,
        // Picker vrací půlnoc posledního dne; bez tohohle by výlet na poslední
        // den okna vypadl.
        windowEnd: windowEnd!.add(const Duration(days: 1)),
        durationMinutes: durationMinutes,
        transport: transport,
        budgetPerPerson: budgetPerPerson,
        activityTags: activityTags.toList(),
        slotStepMinutes: slotStepMinutes,
        dayStart: dayStart,
        dayEnd: dayEnd,
      );

  /// Rozdíl proti uloženému výletu, ve tvaru, který čeká `update_trip`.
  ///
  /// Klíč chybí = neměnit, klíč s null = vymazat. Posílat vždycky všechno by
  /// znamenalo, že každá editace přepíše i pole, kterých se nikdo nedotkl —
  /// a u výletu, kde mezitím někdo jiný něco změnil, by to tiše vyhrálo.
  Map<String, Object?> patchFrom(Trip before) {
    final Map<String, Object?> p = <String, Object?>{};

    if (title.trim() != before.title) p['title'] = title.trim();
    if (_blankToNull(description) != before.description) {
      p['description'] = _blankToNull(description);
    }
    if (windowStart != before.windowStart) {
      p['window_start'] = windowStart!.toUtc().toIso8601String();
    }
    final DateTime end = windowEnd!.add(const Duration(days: 1));
    if (end != before.windowEnd) {
      p['window_end'] = end.toUtc().toIso8601String();
    }
    if (durationMinutes != before.durationMinutes) {
      p['duration_minutes'] = durationMinutes;
    }
    if (slotStepMinutes != before.slotStepMinutes) {
      p['slot_step_minutes'] = slotStepMinutes;
    }
    if (dayStart != before.dayStart) p['day_start'] = _wire(dayStart);
    if (dayEnd != before.dayEnd) p['day_end'] = _wire(dayEnd);

    if (isMeeting) return p;

    if (transport != before.transport) p['transport'] = transport.name;
    if (budgetPerPerson != before.budgetPerPerson) {
      p['budget_per_person'] = budgetPerPerson;
    }
    if (!_sameTags(activityTags, before.activityTags)) {
      // .wire, nikdy .name — ten řetězec je smlouva s pravidly na balení.
      p['activity_tags'] = activityTags.map((ActivityTag t) => t.wire).toList();
    }
    return p;
  }

  /// Co se změnou rozpadne, řečeno předem. Server hlášku nevrací — v tu chvíli
  /// už je pozdě, hlasy jsou smazané.
  List<String> warningsAgainst(Trip before) {
    final List<String> out = <String>[];
    final DateTime end = windowEnd!.add(const Duration(days: 1));

    if (windowStart!.isAfter(before.windowStart) ||
        end.isBefore(before.windowEnd)) {
      out.add('Hlasy pro termíny mimo nové rozmezí se smažou.');
    }
    if (isTimed != (before.durationMinutes < kDayMinutes)) {
      out.add('Změna mezi hodinami a celými dny nabídne jiné termíny, '
          'takže dosavadní hlasování se smaže.');
    } else if (slotStepMinutes != before.slotStepMinutes) {
      out.add('Jiný krok posune nabízené začátky, takže hlasování se smaže.');
    }
    if (before.isDateLocked && durationMinutes != before.durationMinutes) {
      out.add('Zamčený termín začne stejně, ale potrvá nově '
          '${formatDuration(durationMinutes)}.');
    }
    return out;
  }
}

bool _sameTags(Set<ActivityTag> a, List<ActivityTag> b) =>
    a.length == b.length && a.containsAll(b);

String? _blankToNull(String? s) =>
    (s == null || s.trim().isEmpty) ? null : s.trim();

String _wire(Duration d) => '${d.inHours.toString().padLeft(2, '0')}:'
    '${(d.inMinutes % 60).toString().padLeft(2, '0')}:00';
