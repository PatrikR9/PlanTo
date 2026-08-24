/// České texty a ikony časové osy.
///
/// V databázi je klíč a parametry, ne hotová věta (architektura §9.5). Tohle
/// je místo, kde se z nich věta skládá — jediné, a proto se „Přestup" nikde
/// nenapíše dvakrát trochu jinak.
library;

import 'package:flutter/material.dart';

import '../../../core/format/cs_format.dart';
import '../domain/journey.dart';
import '../domain/plan_item.dart';
import '../domain/plan_problem.dart';

/// Hlavní řádek položky.
String planItemTitle(PlanItem item) {
  final Map<String, String> p = item.titleParams;
  switch (item.titleKey) {
    case 'plan.leave_home':
      {
        final String? stop = p['stop'];
        return stop == null || stop.isEmpty
            ? 'Odchod z domova'
            : 'Odchod na $stop';
      }
    case 'plan.walk':
      return 'Pěšky${_arrow(p)}';
    case 'plan.walk_home':
      return 'Cesta domů';
    case 'plan.ride':
      {
        final String from = p['from'] ?? item.fromName ?? '';
        final String to = p['to'] ?? item.toName ?? '';
        if (from.isEmpty && to.isEmpty) return 'Spoj';
        return '$from → $to';
      }
    case 'plan.transfer':
      {
        final String? where = p['stop'];
        return where == null || where.isEmpty
            ? 'Přestup'
            : 'Přestup — $where';
      }
    case 'plan.activity_default':
      {
        final String? place = p['place'];
        return place == null || place.isEmpty ? 'Program' : 'Program v $place';
      }
    default:
      {
        final String? custom = p['title']?.trim();
        return custom != null && custom.isNotEmpty
            ? custom
            : _kindLabel(item.kind);
      }
  }
}

/// Druhý řádek. Vrací null, když by nenesl nic navíc — prázdný řádek pod
/// každou položkou je horší než žádný.
String? planItemSubtitle(PlanItem item) {
  final Map<String, String> p = item.titleParams;
  switch (item.kind) {
    case PlanItemKind.transport:
      {
        final List<String> bits = <String>[
          if (p['line'] != null) p['line']!,
          if (p['operator'] != null) p['operator']!,
          if (item.detail['platform'] is String)
            'nástupiště ${item.detail['platform']}',
          formatLength(item.duration.inMinutes),
        ];
        // Zpoždění se ukazuje jenom, když ho opravdu víme. Nula z chybějících
        // realtime dat by tvrdila, že spoj jede včas.
        final int? delay = _delay(item);
        if (delay != null && delay > 0) bits.add('zpoždění $delay min');
        return bits.isEmpty ? null : bits.join(' · ');
      }
    case PlanItemKind.transfer:
      {
        final String minutes = p['minutes'] ?? '${item.duration.inMinutes}';
        return 'Čekání $minutes min';
      }
    case PlanItemKind.walk:
      return formatLength(item.duration.inMinutes);
    case PlanItemKind.activity:
    case PlanItemKind.free:
    case PlanItemKind.meal:
    case PlanItemKind.accommodation:
    case PlanItemKind.custom:
      {
        final String? note = p['note'];
        final String length = formatLength(item.duration.inMinutes);
        return note == null || note.isEmpty ? length : '$length · $note';
      }
  }
}

String _kindLabel(PlanItemKind k) => switch (k) {
      PlanItemKind.transport => 'Spoj',
      PlanItemKind.walk => 'Pěšky',
      PlanItemKind.transfer => 'Přestup',
      PlanItemKind.activity => 'Program',
      PlanItemKind.free => 'Volno',
      PlanItemKind.meal => 'Jídlo',
      PlanItemKind.accommodation => 'Ubytování',
      PlanItemKind.custom => 'Vlastní bod',
    };

/// Nabídka druhů, které si uživatel může přidat sám. Doprava v ní není:
/// spoj se hledá, nezakládá.
const List<PlanItemKind> kUserAddableKinds = <PlanItemKind>[
  PlanItemKind.activity,
  PlanItemKind.meal,
  PlanItemKind.free,
  PlanItemKind.accommodation,
  PlanItemKind.custom,
];

String planKindLabel(PlanItemKind k) => _kindLabel(k);

String planSegmentLabel(PlanSegment s) => switch (s) {
      PlanSegment.outbound => 'Cesta tam',
      PlanSegment.stay => 'Na místě',
      PlanSegment.homeward => 'Cesta zpět',
    };

IconData planItemIcon(PlanItem item) {
  switch (item.kind) {
    case PlanItemKind.transport:
      return _modeIcon(TransitMode.fromWire(item.detail['mode'] as String?));
    case PlanItemKind.walk:
      return Icons.directions_walk;
    case PlanItemKind.transfer:
      return Icons.swap_horiz;
    case PlanItemKind.activity:
      return Icons.hiking;
    case PlanItemKind.free:
      return Icons.schedule;
    case PlanItemKind.meal:
      return Icons.restaurant;
    case PlanItemKind.accommodation:
      return Icons.hotel;
    case PlanItemKind.custom:
      return Icons.event_note;
  }
}

IconData _modeIcon(TransitMode m) => switch (m) {
      TransitMode.train => Icons.train,
      TransitMode.metro => Icons.subway,
      TransitMode.tram => Icons.tram,
      TransitMode.bus || TransitMode.trolleybus => Icons.directions_bus,
      TransitMode.ferry => Icons.directions_boat,
      TransitMode.car => Icons.directions_car,
      TransitMode.walk => Icons.directions_walk,
      _ => Icons.directions_transit,
    };

/// Věta k problému.
///
/// Konkrétní čísla, ne „něco se nepovedlo". „Nejbližší možný návrat je ve
/// 20:42" je informace, po které se dá zařídit; „nenašli jsme spoj" je
/// slepá ulička.
String planProblemText(PlanProblem p) {
  final String? at = _time(p.params['actual']);
  switch (p.code) {
    case PlanProblemCode.noOutboundFound:
      {
        final String? earliest = _time(p.params['earliest']);
        return earliest == null
            ? 'Na cestu tam se pro zadaný čas nenašel žádný spoj.'
            : 'Na cestu tam se pro zadaný čas nenašel žádný spoj. '
                'Nejbližší možný příjezd je v $earliest.';
      }
    case PlanProblemCode.noReturnFound:
      {
        final String? nearest = _time(p.params['earliest']);
        return nearest == null
            ? 'Na cestu zpět se pro zadaný čas nenašel žádný spoj.'
            : 'Pro návrat v zadaném čase nebyl nalezen vhodný spoj. '
                'Nejbližší možný návrat je v $nearest.';
      }
    case PlanProblemCode.arrivalAfterActivity:
      {
        final String? arrival = _time(p.params['arrival']);
        final String? start = _time(p.params['start']);
        return 'Při příjezdu v ${arrival ?? '?'} nestihnete program, '
            'který začíná v ${start ?? '?'}.';
      }
    case PlanProblemCode.arrivalAfterRequest:
      {
        final String? requested = _time(p.params['requested']);
        return 'Dřív než v ${at ?? '?'} to nejde — chtěli jste do '
            '${requested ?? '?'}.';
      }
    case PlanProblemCode.returnAfterDeadline:
      {
        final String? deadline = _time(p.params['deadline']);
        return 'Domů dorazíte v ${at ?? '?'}, tedy po ${deadline ?? '?'}, '
            'které jste si nastavili.';
      }
    case PlanProblemCode.lockedConflict:
      return 'Zamčené body jsme nechali být, takže se tenhle úsek '
          'nepřepočítal. Odemkněte ho, pokud se má změnit.';
    case PlanProblemCode.userChoiceReplaced:
      return 'Spoj, který jste si vybrali, už do nového zadání nepasoval — '
          'vyměnili jsme ho.';
    case PlanProblemCode.overlap:
      return 'Dva body plánu se překrývají.';
    case PlanProblemCode.noDate:
      return 'Plán potřebuje zamčený termín.';
    case PlanProblemCode.noDestination:
      return 'Plán potřebuje cíl, ke kterému se dá dojet.';
    case PlanProblemCode.noTimetable:
      return 'Časy jsou odhad ze vzdálenosti, ne z jízdního řádu.';
  }
}

String _arrow(Map<String, String> p) {
  final String from = p['from'] ?? '';
  final String to = p['to'] ?? '';
  if (from.isEmpty || to.isEmpty) return '';
  return ' · $from → $to';
}

int? _delay(PlanItem item) {
  final Object? scheduled = item.detail['scheduled_arrival'];
  final Object? real = item.detail['real_time'];
  if (real != true || scheduled is! String) return null;
  final DateTime? s = DateTime.tryParse(scheduled);
  if (s == null) return null;
  return item.endsAt.difference(s).inMinutes;
}

/// Parametry hlášek nesou naivní ISO v zóně výletu. Formátuje se, nepřevádí:
/// je to už čas výletu a druhý převod by ho posunul.
String? _time(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final DateTime? d = DateTime.tryParse(iso);
  return d == null ? null : formatClock(d);
}
