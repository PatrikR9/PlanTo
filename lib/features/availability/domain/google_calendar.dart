import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Připojený účet Googlu, jak ho vidí klient.
///
/// Token tu není a nebude. `my_google_calendar()` ho nevrací — to je celý
/// smysl toho, že výměnu i uložení dělá Edge Function.
@immutable
class GoogleAccount {
  const GoogleAccount({
    required this.connectedAt,
    this.email,
    this.lastSyncedAt,
    this.lastError,
  });

  /// Kvůli jediné větě: „Připojeno jako…". Kdo má dva účty, jinak odpojí ten
  /// špatný. Null u účtu připojeného dřív, než se ukládal e-mail.
  final String? email;
  final DateTime connectedAt;
  final DateTime? lastSyncedAt;

  /// Googlova vlastní slova. Nesloučené do „něco se pokazilo", protože
  /// „souhlas odvolán" a „překročen limit" chtějí od člověka jinou reakci.
  final String? lastError;

  static GoogleAccount fromRow(Map<String, dynamic> r) => GoogleAccount(
        email: r['email'] as String?,
        connectedAt: DateTime.parse(r['connected_at'] as String).toLocal(),
        lastSyncedAt: r['last_synced_at'] == null
            ? null
            : DateTime.parse(r['last_synced_at'] as String).toLocal(),
        lastError: r['last_error'] as String?,
      );
}

/// Nejmenší scope, který Google nabízí: vrací výhradně dvojice začátek–konec.
///
/// Ne `calendar.readonly`. Ten vidí i názvy událostí, místa a účastníky, a
/// slib „nikdy nečteme názvy vašich událostí" by pak držel jen na naší
/// disciplíně místo na oprávnění. Stejná úvaha jako projekce sloupců
/// v PlantoCalendarPlugin.
const String kFreeBusyScope =
    'https://www.googleapis.com/auth/calendar.freebusy';

/// Sestaví adresu obrazovky souhlasu.
///
/// Čistá funkce, protože je to jediné místo, kde se dá udělat chyba, která se
/// projeví až Googlovou chybovou stránkou — tedy tam, kde už nejde nic
/// vysvětlit. Testuje se kus po kuse.
Uri googleConsentUrl({
  required String clientId,
  required String redirectUri,
  required String tripId,
  required bool isWeb,
}) {
  return Uri.https('accounts.google.com', '/o/oauth2/v2/auth', <String, String>{
    'client_id': clientId,
    'redirect_uri': redirectUri,
    'response_type': 'code',
    // openid a email nejsou citlivé scopy a ověření aplikace neovlivňují.
    // Platí se jimi za jméno účtu v UI, což je levné.
    'scope': '$kFreeBusyScope openid email',
    // Bez offline nepřijde refresh token a každá další synchronizace by
    // znamenala další obrazovku souhlasu.
    'access_type': 'offline',
    // A bez consent ho Google podruhé nepošle vůbec — u účtu, který už jednou
    // souhlasil, se vrací jen access token.
    'prompt': 'consent',
    'state': encodeOauthState(tripId: tripId, isWeb: isWeb),
  });
}

/// Co se veze tam a zpátky: kam se má uživatel vrátit a do kterého výletu.
///
/// Base64url, protože to putuje v URL. Bez podpisu a bez nonce, a stojí za to
/// říct proč: kód je jednorázový, vázaný na `redirect_uri`, a vyměňuje ho Edge
/// Function pod JWT toho, kdo o to požádal. Podepisovat navíc údaj, podle
/// kterého se na serveru nic nerozhoduje, by znamenalo další klíč k rotaci
/// výměnou za nic.
String encodeOauthState({required String tripId, required bool isWeb}) {
  final String json = jsonEncode(<String, String>{
    'p': isWeb ? 'web' : 'app',
    't': tripId,
  });
  return base64Url.encode(utf8.encode(json)).replaceAll('=', '');
}
