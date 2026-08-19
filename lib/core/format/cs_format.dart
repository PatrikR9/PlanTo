/// Small Czech-specific formatters shared by more than one screen.
///
/// These are not localisation — `intl` does dates and plurals. They exist for
/// the handful of shapes ICU has no pattern for, and they live here so the
/// same "1,5 h" does not get written three slightly different ways.
library;

/// `7:00`, `18:30`. Czech uses no leading zero on the hour.
///
/// Takes a [Duration] since midnight rather than a `DateTime` because a
/// wall-clock time is not a moment — it is "seven o'clock", on any day.
String formatWallClock(Duration d) =>
    '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}';

/// `30 min`, `1 h`, `1,5 h`. Decimal comma, and never "1.0 h".
String formatLength(int minutes) {
  if (minutes < 60) return '$minutes min';
  if (minutes % 60 == 0) return '${minutes ~/ 60} h';
  return '${(minutes / 60).toStringAsFixed(1).replaceAll('.', ',')} h';
}

/// `2 dny`, `1 den 6 h`, `90 min`. Délka výletu od čtvrthodiny po měsíc.
///
/// [formatLength] končí u hodin, protože vzniklo pro délku slotu. Od M13 je
/// délka jedno pole přes celý rozsah, takže potřebuje i dny — a s nimi české
/// tři tvary množného čísla, na které v intl není vzor.
String formatDuration(int minutes) {
  if (minutes < 1440) return formatLength(minutes);

  final int days = minutes ~/ 1440;
  final int rest = minutes % 1440;
  final String d = '$days ${pluralDays(days)}';
  return rest == 0 ? d : '$d ${formatLength(rest)}';
}

/// `den` / `dny` / `dní`. Čeština má tři tvary a hranice nejsou u jedničky,
/// ale mezi 4 a 5.
String pluralDays(int n) {
  if (n == 1) return 'den';
  if (n >= 2 && n <= 4) return 'dny';
  return 'dní';
}

/// `1 člověk` / `3 lidé` / `5 lidí`.
///
/// Náhled pozvánky ukazoval „3 lidí", protože podmínka znala jen jedničku
/// a všechno ostatní. Je to první věta, kterou o výletu uvidí někdo, kdo
/// aplikaci nezná, a špatný tvar v ní je drobnost, které si každý Čech všimne.
String formatPeople(int n) {
  if (n == 1) return '1 člověk';
  if (n >= 2 && n <= 4) return '$n lidé';
  return '$n lidí';
}

/// Poslední den okna, ve tvaru pro člověka.
///
/// `trips.date_window` je půlotevřený interval `[start, end)`, takže jeho horní
/// mez je den PO posledním použitelném dnu. Vypsat ji rovnou znamená slíbit
/// skupině o den víc, než na kolik se doopravdy hledá termín — a je to chyba,
/// kterou nikdo nenahlásí, protože ten den prostě jen nikdy nevyjde.
///
/// Počítá se po kalendářních dnech, ne odečtením 24 hodin. Na přechodu času
/// má den 23 nebo 25 hodin a odečtená doba by spadla o hodinu vedle — což je
/// tentýž důvod, proč mřížka dostupnosti postupuje přes `DateTime(y, m, d + 1)`.
DateTime lastDayOfWindow(DateTime endExclusive) =>
    DateTime(endExclusive.year, endExclusive.month, endExclusive.day - 1);

/// Czech weekday and month names come out of intl lowercase, which reads as a
/// typo at the start of a line.
String capitalise(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
