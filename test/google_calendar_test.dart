import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:planto/features/availability/domain/google_calendar.dart';

void main() {
  // Adresa obrazovky souhlasu je jediné místo v celém toku, kde se chyba
  // projeví až Googlovou chybovou stránkou — tedy tam, kde už nejde nic
  // vysvětlit ani odchytit. Proto po kusech.
  group('googleConsentUrl', () {
    final Uri url = googleConsentUrl(
      clientId: '123.apps.googleusercontent.com',
      redirectUri: 'https://patrikr9.github.io/PlanTo/oauth.html',
      tripId: 'aaaa-bbbb',
      isWeb: true,
    );

    test('míří na obrazovku souhlasu Googlu', () {
      expect(url.host, 'accounts.google.com');
      expect(url.path, '/o/oauth2/v2/auth');
    });

    test('žádá jen o obsazenost', () {
      // calendar.readonly by vidělo i názvy událostí a slib „nečteme nadpisy"
      // by pak držel jen na naší disciplíně. Kdyby tenhle test spadl kvůli
      // rozšířenému scope, není to test, co se má opravit.
      final List<String> scopes = url.queryParameters['scope']!.split(' ');
      expect(scopes, contains(kFreeBusyScope));
      expect(
        scopes.any((String s) => s.contains('calendar.readonly')),
        isFalse,
      );
    });

    test('žádá o refresh token, jinak by se souhlas opakoval pokaždé', () {
      expect(url.queryParameters['access_type'], 'offline');
      // Bez prompt=consent Google u účtu, který už jednou souhlasil, refresh
      // token podruhé nepošle — a synchronizace by pak fungovala přesně jednou.
      expect(url.queryParameters['prompt'], 'consent');
      expect(url.queryParameters['response_type'], 'code');
    });

    test('nese výlet a platformu ve state', () {
      final Map<String, dynamic> state = _decodeState(
        url.queryParameters['state']!,
      );
      expect(state['t'], 'aaaa-bbbb');
      expect(state['p'], 'web');
    });

    test('na Androidu se vrací do aplikace, ne do prohlížeče', () {
      final Uri app = googleConsentUrl(
        clientId: 'x',
        redirectUri: 'https://example.com/oauth.html',
        tripId: 't',
        isWeb: false,
      );
      expect(_decodeState(app.queryParameters['state']!)['p'], 'app');
      // Redirect URI zůstává tatáž stránka i na Androidu: Google nepovoluje
      // vlastní schéma u klienta, který má secret. Přesměrování do aplikace
      // dělá až ta stránka.
      expect(app.queryParameters['redirect_uri'],
          'https://example.com/oauth.html');
    });
  });

  test('state je base64url bez výplně, aby přežil cestu v URL', () {
    final String s = encodeOauthState(tripId: 'aaaa-bbbb', isWeb: true);
    expect(s.contains('='), isFalse);
    expect(s.contains('+'), isFalse);
    expect(s.contains('/'), isFalse);
  });
}

Map<String, dynamic> _decodeState(String s) {
  final String padded = s.padRight((s.length + 3) ~/ 4 * 4, '=');
  return jsonDecode(utf8.decode(base64Url.decode(padded)))
      as Map<String, dynamic>;
}
