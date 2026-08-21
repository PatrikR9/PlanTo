import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:planto/app/env/env.dart';
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
      expect(
        app.queryParameters['redirect_uri'],
        'https://example.com/oauth.html',
      );
    });
  });

  // Návratová adresa je jediná hodnota v celém toku, kterou Google porovnává
  // znak po znaku a na neshodu odpoví `redirect_uri_mismatch` — tedy až na
  // vlastní chybové stránce. Na webu se navíc odvozuje z běhové adresy, takže
  // je to i to, co drží pozvaného na jednom originu a s jednou anonymní
  // session.
  group('oauthRedirectForPage', () {
    test('web pod podadresářem na GitHub Pages', () {
      expect(
        Env.oauthRedirectForPage(
          Uri.parse('https://patrikr9.github.io/PlanTo/#/trips/abc'),
        ),
        'https://patrikr9.github.io/PlanTo/oauth.html',
      );
    });

    test('index.html v adrese nesmí skončit v návratové adrese', () {
      expect(
        Env.oauthRedirectForPage(
          Uri.parse('https://patrikr9.github.io/PlanTo/index.html'),
        ),
        'https://patrikr9.github.io/PlanTo/oauth.html',
      );
    });

    test('chybějící koncové lomítko se doplní, ne uřízne adresář', () {
      // `/PlanTo` bez lomítka je pořád adresář. Kdyby se z něj stalo `/`,
      // odešlo by Googlu https://patrikr9.github.io/oauth.html a přišlo by
      // redirect_uri_mismatch.
      expect(
        Env.oauthRedirectForPage(
          Uri.parse('https://patrikr9.github.io/PlanTo'),
        ),
        'https://patrikr9.github.io/PlanTo/oauth.html',
      );
    });

    test('lokální flutter run -d chrome zůstává na localhostu', () {
      // Tohle je ta oprava: dřív se odvozovalo z INVITE_BASE, které
      // env/dev.json nenastavuje, takže se i z localhostu posílala adresa
      // GitHub Pages —
      // a Google vracel uživatele na jiný origin, tedy do jiné session.
      expect(
        Env.oauthRedirectForPage(Uri.parse('http://localhost:5173/#/trips')),
        'http://localhost:5173/oauth.html',
      );
    });
  });

  // Android se vrací na hostovanou stránku odvozenou z INVITE_BASE. Tenhle
  // výpočet byl rozbitý o jediný znak a projevilo se to až Googlovou stránkou
  // `redirect_uri_mismatch`, kde se odeslaná adresa vůbec nezobrazuje.
  group('hostedOauthRedirectFor', () {
    test('z INVITE_BASE končícího /i zůstane lomítko oddělující adresář', () {
      // `substring(length - 2)` uřízlo `/i` včetně lomítka a vyrobilo
      // `https://patrikr9.github.io/PlanTooauth.html`.
      expect(
        Env.hostedOauthRedirectFor('https://patrikr9.github.io/PlanTo/i'),
        'https://patrikr9.github.io/PlanTo/oauth.html',
      );
    });

    test('adresa v kořeni domény', () {
      expect(
        Env.hostedOauthRedirectFor('https://planto.app/i'),
        'https://planto.app/oauth.html',
      );
    });

    test('INVITE_BASE bez /i dostane lomítko navíc', () {
      expect(
        Env.hostedOauthRedirectFor('https://planto.app'),
        'https://planto.app/oauth.html',
      );
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
