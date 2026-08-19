import 'package:flutter_test/flutter_test.dart';
import 'package:planto/core/format/cs_format.dart';

void main() {
  // Čeština má tři tvary množného čísla a hranice není u jedničky, ale mezi
  // 4 a 5. Podmínka „jedna versus všechno ostatní" vyrobí „3 lidí", což je
  // drobnost, které si každý Čech všimne — a je to první věta, kterou o výletu
  // uvidí někdo, kdo aplikaci nezná.
  group('formatPeople', () {
    test('má všechny tři tvary', () {
      expect(formatPeople(1), '1 člověk');
      expect(formatPeople(2), '2 lidé');
      expect(formatPeople(4), '4 lidé');
      expect(formatPeople(5), '5 lidí');
      expect(formatPeople(11), '11 lidí');
    });
  });

  group('formatDuration', () {
    test('pod hodinu minuty, nad hodinu hodiny', () {
      expect(formatDuration(30), '30 min');
      expect(formatDuration(60), '1 h');
      expect(formatDuration(90), '1,5 h');
    });

    test('od jednoho dne dny, se správným tvarem', () {
      expect(formatDuration(1440), '1 den');
      expect(formatDuration(2 * 1440), '2 dny');
      expect(formatDuration(7 * 1440), '7 dní');
    });

    test('zbytek se připojí, ne zaokrouhlí', () {
      // „1 den" u třicetihodinové akce by tvrdilo, že se stihne za den.
      expect(formatDuration(1440 + 360), '1 den 6 h');
    });
  });

  // date_window je [start, end), takže end je den PO posledním použitelném.
  // Vypsaný rovnou slibuje skupině o den víc, než na kolik se hledá termín —
  // a je to chyba, kterou nikdo nenahlásí, protože ten den prostě jen nikdy
  // nevyjde jako kandidát.
  group('lastDayOfWindow', () {
    test('vrací půlnoc i přes přechod letního času', () {
      // Odečtení 24 hodin by tady vrátilo 25. 10. v 01:00, protože ten den má
      // 25 hodin. Na výpis data by to nebylo poznat a na čemkoli dalším ano.
      expect(lastDayOfWindow(DateTime(2026, 10, 26)), DateTime(2026, 10, 25));
      expect(lastDayOfWindow(DateTime(2026, 3, 30)), DateTime(2026, 3, 29));
    });

    test('přes hranici měsíce', () {
      expect(lastDayOfWindow(DateTime(2026, 9, 1)), DateTime(2026, 8, 31));
      expect(lastDayOfWindow(DateTime(2027, 1, 1)), DateTime(2026, 12, 31));
    });
  });
}
