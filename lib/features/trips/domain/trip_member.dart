import 'package:flutter/foundation.dart';

/// Jeden člověk ve výletu, jménem.
///
/// Přehled do teď uměl jen počty. „3 z 3 sdílelo dostupnost" odpovídá na
/// otázku „můžeme plánovat", ale ne na tu, kterou organizátor doopravdy má —
/// „na koho ještě čekám". Bez jména se nedá nikoho pobídnout.
@immutable
class TripMember {
  const TripMember({
    required this.userId,
    required this.displayName,
    required this.calendarShared,
    required this.isOrganiser,
    required this.isMe,
  });

  factory TripMember.fromRow(Map<String, dynamic> row) {
    final String name = (row['display_name'] as String? ?? '').trim();
    return TripMember(
      userId: row['user_id'] as String,
      // Prázdné jméno je stav, ne chyba: profil vzniká dřív, než se člověk
      // stihne pojmenovat. Fallback je tentýž, jaký dává handle_new_user.
      displayName: name.isEmpty ? 'Cestovatel' : name,
      calendarShared: row['calendar_shared'] as bool? ?? false,
      isOrganiser: row['is_organiser'] as bool? ?? false,
      isMe: row['is_me'] as bool? ?? false,
    );
  }

  final String userId;
  final String displayName;
  final bool calendarShared;
  final bool isOrganiser;
  final bool isMe;
}
