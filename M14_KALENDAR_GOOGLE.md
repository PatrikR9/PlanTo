# M14 — kalendář Googlem, jedním klepnutím

Návrh ze 14. srpna 2026. Vzniklo z jednoho zjištění při testování: pozvaný,
který přijde z odkazu ve skupinovém chatu, skončí v prohlížeči — a tam nemá
aplikace k jeho kalendáři žádný přístup. Zbývá mu vložit tajnou iCal adresu,
což je pět kroků v cizí aplikaci, nebo naklikat dostupnost ručně.

## 1. Proč OAuth a ne oprava UI

Prohlížeč nemá žádné API ke kalendáři v zařízení. Není to chybějící tlačítko,
je to chybějící platforma. Jednoklikové připojení na webu tedy znamená mluvit
s poskytovatelem kalendáře, a to znamená OAuth.

Aplikace na Androidu tímhle netrpí — `planto_calendar` čte `CalendarProvider`
napřímo a je to jedno klepnutí už teď. Google je tedy cesta pro **web**, a na
Androidu druhá možnost pro toho, kdo systémovému kalendáři nevěří nebo ho má
prázdný.

## 2. Scope: `calendar.freebusy`, ne `calendar.readonly`

Google nabízí obojí. `calendar.readonly` vidí i názvy událostí, místa a
účastníky. `calendar.freebusy` neumí vrátit nic než dvojice začátek–konec.

Tahle volba je celý důvod, proč projekt může slíbit „nikdy nečteme názvy
vašich událostí" a myslet to strukturálně. Je to stejná úvaha jako projekce
sloupců v `PlantoCalendarPlugin`: slib vynucený oprávněním, ne disciplínou.

Cena: `freeBusy` se ptá jen primárního kalendáře. Vypsat ostatní vyžaduje
`calendar.readonly`, tedy přesně tu výměnu, kterou neděláme. Kdo má obsazenost
rozházenou po víc kalendářích, má pořád iCal odkaz — ten zůstává.

**`calendar.freebusy` je u Googlu „sensitive" scope.** Bez ověření aplikace
platí strop 100 uživatelů a varovná obrazovka „Google tuto aplikaci neověřil".
Ověření chce ověřenou doménu, zásady ochrany soukromí a video — tedy
`planto.app`. Pro fázi testerů na Play (14 lidí) je strop bez významu; do
produkce se bez domény stejně nejde.

## 3. Tok

```
klient ──▶ accounts.google.com/o/oauth2/v2/auth
             scope=calendar.freebusy openid email
             access_type=offline · prompt=consent
             redirect_uri=<pages>/oauth.html
             state=base64url({p:"web"|"app", t:<trip>, n:<nonce>})
                     │
                     ▼
           docs/oauth.html  ← kód se tu NEVYMĚŇUJE, jen přeposílá
             ├─ p=app → app.planto://calendar-callback?code=…
             └─ p=web → <pages>/#/calendar-callback?code=…
                     │
                     ▼
           Edge Function google-calendar   (client_secret je tady)
             ├─ code → tokeny, refresh_token zašifrovaný do DB
             ├─ refresh → access token
             ├─ freeBusy(timeMin, timeMax, primary)
             ├─ ořez · zaokrouhlení ven na 15 min · sloučení
             └─ nahradit busy_intervals · calendar_shared = true
```

**Proč statická stránka uprostřed.** Google nepovoluje vlastní schéma
(`app.planto://`) u klienta typu *Web application*, a ten typ je nutný, protože
jen on má `client_secret`. Bez tajemství na serveru by výměnu kódu musel dělat
klient, což ruší pravidlo „klient nikdy nemluví přímo se třetí stranou".
Jeden OAuth klient, jedna povolená redirect URI, rozcestník v `docs/oauth.html`.

**Kód se do prohlížeče dostane, `client_secret` nikdy.** Autorizační kód je
jednorázový, vázaný na `redirect_uri` a bez tajemství se za tokeny vyměnit
nedá.

## 4. Co se ukládá

`google_calendar_accounts` — jeden řádek na člověka:

| sloupec | proč |
|---|---|
| `refresh_cipher` | base64(iv ‖ AES-GCM). Klíč je `ICAL_SECRET`, sdílený s iCal — tentýž druh tajemství, a dvě rotace znamenají jednu zapomenutou. |
| `email` | jediná věta v UI: „Připojeno jako…". Kdo má dva účty, jinak odpojí ten špatný. |
| `scope` | Google smí schválit míň, než se žádalo. Bez uložení se to pozná až prvním 403. |
| `last_error` | Googlova vlastní slova. „Souhlas odvolán" a „limit překročen" chtějí jinou reakci. |

Tabulka má RLS **bez jediné politiky** a odebrané granty. Není to opomenutí:
sahá na ni výhradně service role uvnitř funkce. Klient vidí jen
`my_google_calendar()`, která token nevrací a vracet nebude — stejné pravidlo
jako `my_calendar_feeds()`.

`disconnect_google_calendar()` maže i bloky, které účet vyrobil. U iCal odkazu
zůstávají; ten rozdíl je záměrný. Odpojit odkaz znamená „už to nechci
aktualizovat", odpojit účet znamená „už o mně nic nemějte".

## 5. Co musíš udělat ty, než to začne fungovat

Bez těchhle kroků se nic z napsaného nespustí.

**Google Cloud** (console.cloud.google.com)

1. Nový projekt, například `planto`.
2. **APIs & Services → Library → Google Calendar API → Enable.**
3. **OAuth consent screen**: External. Název aplikace PlanTo, podpůrný e-mail,
   logo nepovinné. Scope přidat `.../auth/calendar.freebusy` — a nic víc.
   `openid` a `email` jsou neutrální a ověření neovlivňují.
4. **Test users**: dokud je aplikace v režimu Testing, přihlásit se smí jen
   e-maily z tohohle seznamu. Přidej sebe a testery.
5. **Credentials → Create credentials → OAuth client ID → Web application.**
   Authorized redirect URIs, přesně a bez lomítka navíc — obě:
   `https://patrikr9.github.io/PlanTo/oauth.html`
   `http://localhost:5173/oauth.html`

   Ta druhá je kvůli `flutter run -d chrome --web-port 5173`. Bez ní se dá tok
   vyzkoušet až po nasazení, protože Google se vrací jen na adresu, kterou má
   zapsanou — a čekat na deploy kvůli každé změně je ten nejjistější způsob,
   jak se přestat obtěžovat s testováním.
6. Zkopíruj **Client ID** a **Client secret**.

**Supabase**

```
supabase secrets set GOOGLE_CLIENT_ID="…"
supabase secrets set GOOGLE_CLIENT_SECRET="…"
supabase secrets set ICAL_SECRET="$(openssl rand -base64 32)"   # jen pokud ještě není
supabase functions deploy google-calendar
supabase db push
```

**Build**

Client ID je veřejný (jde v URL), secret nikdy. Do buildu se předává
`--dart-define=GOOGLE_CALENDAR_CLIENT_ID=…`; workflow `apk.yml` a `pages.yml`
ho vezmou ze stejného repozitářového secretu jako zbytek.

Kontrola, že krok 5 sedí: otevři `https://patrikr9.github.io/PlanTo/oauth.html`
v prohlížeči. Musí říct „Chybí návratový kód." Když vrátí 404, stránka není
nasazená a Google odmítne přesměrovat dřív, než se uživatel k něčemu dostane.

## 6. Stav

| část | stav |
|---|---|
| migrace `20260814090000_google_calendar.sql` | **aplikovaná** 14. 8. |
| Edge Function `google-calendar` | **nasazená** 14. 8. |
| `web/oauth.html` | **nasazená** 14. 8. |
| intent filter `app.planto://calendar-callback` | napsáno |
| Flutter: tlačítko, callback routa, `/calendar-callback` | napsáno, 74 testů zelených |
| Google Cloud projekt a klient | hotovo, ověřeno ruční adresou souhlasu |
| `GOOGLE_CALENDAR_CLIENT_ID` v `env/dev.json` | hotovo |
| `GOOGLE_CALENDAR_CLIENT_ID` jako GitHub secret | **chybí** — bez něj nasazený web a APK z CI tlačítko neukáží |
| celý tok od klepnutí po obsazenost | příčina nalezena 21. 8., viz oddíl 9 |

Prázdné client ID tlačítko schová — to je záměr, ne obrana. Tlačítko, které
skončí na chybové stránce Googlu, stojí víc důvěry než tlačítko, které tam
není.

## 7. Kde to stálo 14. srpna

> Historický záznam. Aktuální stav je v oddílu 9.

**Stav ke 14. srpnu 2026: nedořešeno.** Připojení kalendáře končí na obrazovce
Googlu:

```
Access blocked: Authorization Error
The OAuth client was not found.
Error 401: invalid_client
```

Tenhle oddíl existuje proto, aby se příště nezačínalo od nuly. Je v něm, co je
prokázané, co je vyloučené a čím se pokračuje.

### 7.1 Co je prokázané

**Klient v Google Cloudu existuje a je správně nastavený.** Ověřeno tak, že se
adresa souhlasu sestavila ručně s Client ID zkopírovaným přímo z Credentials:

```
https://accounts.google.com/o/oauth2/v2/auth
  ?client_id=<z konzole>
  &redirect_uri=https%3A%2F%2Fpatrikr9.github.io%2FPlanTo%2Foauth.html
  &response_type=code
  &scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.freebusy
  &access_type=offline&prompt=consent
```

Tahle adresa došla až k **výběru účtu**. To vylučuje dvě věci naráz: kdyby bylo
špatné Client ID, `invalid_client` přijde dřív než jakákoli obrazovka; kdyby
nesouhlasila redirect URI, přijde `redirect_uri_mismatch`. Obojí prošlo.

**Hodnota v `env/dev.json` je tvarově bezvadná.** Ověřeno strojově: 72 znaků,
`739320162735-` + 32 malých alfanumerických znaků + `.apps.googleusercontent.com`,
žádné bílé znaky, žádné neočekávané znaky. Patrik potvrdil, že je i obsahově
správná.

**Pozvánkový řetězec funguje.** Odkaz, náhled, připojení i sdílení dostupnosti
projdou na nasazeném webu i na telefonu. S Google autorizací nesouvisí.

### 7.2 Co je vyloučené

| hypotéza | proč padla |
|---|---|
| smazaný nebo neexistující klient | ruční adresa došla k výběru účtu |
| špatná redirect URI | jinak by přišlo `redirect_uri_mismatch`, ne `invalid_client` |
| bílý znak v hodnotě | kontrola tvaru neukázala žádný; navíc od 14. 8. se ořezává |
| chybějící test users | `invalid_client` nastane dřív, než Google řeší, kdo smí souhlasit |
| publishing status | totéž — týká se pozdějšího kroku |
| chybějící Client ID v buildu | pak by se tlačítko vůbec nezobrazilo |

Pozor na ty dvě prostřední. Test users i přepnutí do produkce se během ladění
měnily a **ani jedno na `invalid_client` nemá vliv**. Řeší se jimi až obrazovka
souhlasu, tedy krok, ke kterému se to zatím nedostalo.

### 7.3 Co zbývá jako vysvětlení

Běžící build tu správnou hodnotu nemá. Dvě nezávislé cesty, jak k tomu dojít:

**`--dart-define-from-file` se čte při startu příkazu.** Úprava `env/dev.json`
za běhu se do běžícího `flutter run` nedostane — ani hot reloadem, ani `R`.
`String.fromEnvironment` je konstanta vyhodnocená při kompilaci.

**Intent filter přibyl ve stejném commitu.** `app.planto://calendar-callback`
je nový záznam v `AndroidManifest.xml` a manifest se promítne až celým
přestavěním APK. I kdyby souhlas prošel, návrat z prohlížeče by aplikaci
nenašel.

### 7.4 Čím pokračovat

1. Ukončit `flutter run` (`q`) a spustit znovu — ne restart, ne hot reload:
   `flutter run -d emulator-5554 --dart-define-from-file=env/dev.json`
2. Když chyba trvá, přečíst `client_id` **z adresního řádku** té chybové
   stránky a porovnat s `env/dev.json`. Liší-li se, běží pořád starý build.
   Shodují-li se, je příčina jinde než v hodnotě a je čas na `flutter logs`.
3. Teprve až projde obrazovka souhlasu, řešit test users a Supabase secrets.

### 7.5 Tři místa, kde žije Google konfigurace

Rozdělení, na kterém se dá snadno uklouznout — pokaždé jiné jméno pro
podobnou věc:

| kde | co | k čemu |
|---|---|---|
| `env/dev.json` | `GOOGLE_CALENDAR_CLIENT_ID` | lokální běh, jen ID |
| GitHub → Actions secrets | `GOOGLE_CALENDAR_CLIENT_ID` | nasazený web a APK z CI, jen ID |
| Supabase secrets | `GOOGLE_CLIENT_ID` **a** `GOOGLE_CLIENT_SECRET` | Edge Function, výměna kódu za tokeny |

Client ID je veřejné — jede v URL a je v každém buildu. Tajný je jen
`GOOGLE_CLIENT_SECRET` a ten smí existovat výhradně jako secret Edge Function.
Když se klient v konzoli smaže a založí znovu, **mění se i secret** a Supabase
o tom neví: souhlas by prošel a spadla by až výměna kódu, tedy o krok později
a už z naší strany.

### 7.6 Kdo se smí připojit

Dvě nastavení, která spolu nesouvisí, ale obě umí vypadat jako chyba:

**Testing.** Připojí se jen účet ručně přidaný v Google Auth Platform →
Audience → Test users. Ostatní dostanou „access denied". Navíc **souhlas
testera vyprší po sedmi dnech** — přijde to jako „najednou to přestalo
fungovat".

**In production, neověřená.** Připojí se kdokoli, ale s varovnou obrazovkou
„Google tuto aplikaci neověřil" a se stropem **100 uživatelů za celou dobu
života projektu**, který se nedá resetovat. Není to sto najednou, je to sto
souhlasů celkem. Vyplýtvat ho na náhodné zkoušení znamená buď verifikaci, nebo
nový Cloud projekt s novým Client ID a přenastavením všude.

Verifikace odemkne obojí a vyžaduje ověřenou doménu, zásady ochrany soukromí
a video — tedy `planto.app`. Je to tatáž doména, kterou už potřebuje App Links
a e-maily; není to další položka, jen další důvod.

**Co tím není blokované:** pozvánka. Kdo se ke Googlu nedostane, otevře odkaz,
připojí se bez registrace a dostupnost zadá ručně nebo přes iCal odkaz. Ty dvě
cesty nejsou náhradní řešení, jsou to plnohodnotné varianty — a existují právě
proto, že Google nikdy nebude dostupný všem.

## 8. Past, do které jsem tě poslal

`openssl` na Windows není a `"$(openssl rand -base64 32)"` se v PowerShellu
vyhodnotí na prázdný řetězec — `supabase secrets set` ho pak vesele uloží.
Prázdné `ICAL_SECRET` shodí obě funkce, které z něj dělají klíč, tedy i
`ical-sync`, který s tím nemá nic společného.

```powershell
$b = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
supabase secrets set ICAL_SECRET="$([Convert]::ToBase64String($b))"
```

Když byl klíč nastavený už dřív, přepsáním se ztratil a uložené iCal adresy se
nedají rozšifrovat: `delete from calendar_feeds;` a vložit odkaz znovu. Šifra
bez klíče není poškozená data, je to jen náhodný šum — a odkaz, který se nedá
načíst, je horší než žádný, protože skupina čeká na dostupnost, která nikdy
nepřijde.


## 9. 21. srpna — co se zúžilo a co se opravilo

Chyba je pořád `Error 401: invalid_client — The OAuth client was not found`,
ale ptá se na ni jiné prostředí než v srpnu: **nasazený web na GitHub Pages**,
otevřený z pozvánkového odkazu v prohlížeči na počítači. Publishing status je
mezitím **In production**, takže Testing ani Test users v tomhle nehrají roli
— `invalid_client` přijde dřív, než Google řeší, kdo smí souhlasit.

### 9.1 Příčina: v nasazeném buildu je Client ID s výpustkou

Změřeno přímo v prohlížeči na `main.dart.js` z Pages. Nasazená hodnota je:

```
739320162735-…apps.googleusercontent.com
```

**40 znaků místo 72**, a na místě prostředního třiatřicetiznakového úseku
(32 znaků + tečka) je jediný znak **U+2026, výpustka `…`**.

To je hodnota **zkopírovaná z výpisu v Google Cloud Console**, kde se Client ID
zobrazuje zkrácené právě takhle. Sedla si do GitHub secretu
`GOOGLE_CALENDAR_CLIENT_ID`, odkud ji bere `pages.yml` i `apk.yml`.

Proč to přežilo všechny dosavadní obrany:

- **není prázdná**, takže `googleCalendarEnabled` je true a tlačítko se zobrazí;
- **neobsahuje bílý znak**, takže `.trim()` z commitu `764ce81` nemá co udělat;
- **na oko vypadá správně** — začíná správným číslem projektu a končí správnou
  doménou.

Google na ni odpoví `401 invalid_client: The OAuth client was not found`, což
vypadá jako smazaný klient. Odtud těch sedm dní hledání v konzoli.

`env/dev.json` je v pořádku (72 znaků, tvar sedí) — proto lokální a emulátorové
buildy tímhle netrpěly a proto ruční adresa souhlasu v oddílu 7.1 došla až
k výběru účtu. Rozbité byly **jen buildy z CI**.

### 9.2 Čím je to potvrzené

Adresa souhlasu sestavená s plnou hodnotou z `env/dev.json` a produkční
`redirect_uri` došla 21. 8. k **výběru účtu** („Pokračovat do aplikace
patrikr9.github.io"). Jedno kliknutí tím vyloučilo čtyři věci naráz:

| ověřeno | protože by jinak přišlo |
|---|---|
| klient existuje | `invalid_client` |
| redirect URI je zapsaná | `redirect_uri_mismatch` |
| scope je přijatý | `invalid_scope` |
| publishing status pouští dovnitř | `access_denied` |

Google Auth Platform → Audience: **In production**, External,
**0 users / 100 user cap** — nikdo souhlas nikdy nedokončil, což sedí.

### 9.3 Co se přitom opravilo v kódu

Tři vady, které s `invalid_client` nesouvisí, ale ležely na téže cestě.

**Návratová adresa se na webu odvozovala z `INVITE_BASE`.** `env/dev.json`
žádné `INVITE_BASE` nenastavuje, takže i `flutter run -d chrome` posílal
Googlu adresu na GitHub Pages. Google se vrátil na **jiný origin**, tedy do
jiného localStorage, tedy pod jinou anonymní Supabase session — pozvaný
uprostřed toku přišel o členství ve výletu. Zapsaná `http://localhost:5173/oauth.html`
byla tím pádem mrtvá konfigurace: kód ji nikdy neposlal. Nově se na webu
`oauth.html` bere ze skutečné adresy, na které aplikace běží.

**Auth guard v routeru spolkl `/calendar-callback`.** Nepřihlášeného posílal na
`/auth?from=<cesta>` a `from` nese jen cestu, ne query — takže se zahodilo
`?code=`. Autorizační kód je jednorázový, takže druhý pokus neexistoval.
Callback je teď z guardu vyňatý, stejně jako pozvánka.

**`oauth.html` chybu nikdy neposlala dál.** Na „Zrušit" skončil člověk na cizí
doméně bez cesty zpátky, zatímco `CalendarCallbackScreen` má pro ten případ
napsanou větu i tlačítko „Zadat dostupnost jinak". Chyba se teď přeposílá do
aplikace jako `?error=…`.

Navíc: `Env.googleCalendarClientIdLooksValid` kontroluje tvar Client ID a
tlačítko místo odchodu na Googlovu chybovou stránku řekne česky, že je build
špatně nastavený. `pages.yml` i `apk.yml` teď ze secretu stripují bílé znaky
a `pages.yml` varuje, když je prázdný.

### 9.4 Co je potřeba udělat

1. **GitHub → Settings → Secrets and variables → Actions →
   `GOOGLE_CALENDAR_CLIENT_ID`.** Vlož plnou hodnotu. V konzoli použij
   **ikonu kopírování** u klienta, ne označení zobrazeného textu — zobrazený
   text je zkrácený a přesně tím to začalo.
2. **Actions → Deploy web to Pages → Run workflow.** Změna secretu sama
   nasazení nespouští; bez tohohle kroku zůstane na webu stará zkompilovaná
   hodnota.
3. Totéž platí pro **APK z CI** — bere tentýž secret, takže bylo rozbité stejně.

### 9.5 Scope: konzole odpovídá, ale na jinou otázku

Verification Center (21. 8.) hlásí:

> Verification is not required since your app is not requesting any sensitive
> or restricted scopes.

**Tohle není důkaz, že `calendar.freebusy` je non-sensitive.** Data Access má
všechny tři tabulky prázdné — nedeklarovaný je ani `calendar.freebusy`, ani
`openid`, ani `email` — a konzole hodnotí to, co je deklarované, ne to, co
aplikace za běhu opravdu žádá.

Odpověď se dostane jedním krokem, který se stejně musí udělat: **Data Access →
Add or remove scopes → přidat `.../auth/calendar.freebusy` → Save.** Do které
ze tří tabulek spadne, to je ta odpověď:

- **non-sensitive** → v produkci žádná verifikace, žádná varovná obrazovka,
  žádný strop. Hotovo.
- **sensitive** → kdokoli se připojí, ale přes „Google tuto aplikaci
  neověřil", se stropem 100 souhlasů za život projektu. Verifikace pak chce
  ověřenou doménu v Search Console, homepage a zásady ochrany soukromí na
  téže doméně — tedy `planto.app`, ne `github.io`.

Vedle toho: **Branding status = „Your branding is not being shown to users."**
Proto obrazovka souhlasu říká „Pokračovat do aplikace **patrikr9.github.io**"
místo „PlanTo". Nic to neblokuje, ale pozvanému, který o aplikaci nikdy
neslyšel, to důvěru nepřidá.

Projekt v konzoli: **`planto-505515`**.


## 10. Druhá příčina: návratová adresa byla o jeden znak vedle

Po opravě secretu se chyba posunula na:

```
Access blocked: This app's request is invalid
Error 400: redirect_uri_mismatch
```

To je postup, ne nová porucha: `invalid_client` přichází dřív než kontrola
redirect URI, takže druhá vada byla celou dobu schovaná za první.

### 10.1 Ten znak

Původní výpočet v `Env.oauthRedirectUri`:

```dart
final String base = inviteBase.endsWith('/i')
    ? inviteBase.substring(0, inviteBase.length - 2)   // <-- tady
    : '$inviteBase/';
return '${base}oauth.html';
```

`INVITE_BASE` je `https://patrikr9.github.io/PlanTo/i`, tedy 35 znaků.
`substring(0, 33)` uřízne **`/i` včetně lomítka** a zbyde
`https://patrikr9.github.io/PlanTo`. Po připojení `oauth.html` z toho je:

```
https://patrikr9.github.io/PlanTooauth.html
```

`PlanTo` a `oauth.html` slepené dohromady. Adresa, která na první pohled
vypadá skoro správně, kterou Google ve své chybové hlášce **vůbec nezobrazí**,
a která se v kompilovaném `main.dart.js` nedá najít ani hledáním — vzniká až
za běhu ze `substring`, takže v konstantách je vidět jen nepoužitá větev
`…/PlanTo/i/oauth.html`.

Uříznout se má **jen `i`**, ne `/i`: `length - 1`. To lomítko je oddělovač
adresáře.

### 10.2 Proč to neodhalil žádný test

`test/google_calendar_test.dart` předával `redirectUri` jako parametr, takže
testoval `googleConsentUrl`, ale nikdy ne výpočet té adresy. Ta jediná hodnota,
která se dá zkazit tak, že se to projeví až na cizí doméně, byla jediná bez
pokrytí. Teď má tři testy (`hostedOauthRedirectFor`) plus čtyři na webovou
větev (`oauthRedirectForPage`).

### 10.3 Stav po opravě

| hodnota | odesílá se |
|---|---|
| web (nasazený i localhost) | z běhového originu — `https://patrikr9.github.io/PlanTo/oauth.html`, resp. `http://localhost:5173/oauth.html` |
| Android | `hostedOauthRedirectFor(INVITE_BASE)` → `https://patrikr9.github.io/PlanTo/oauth.html` |

Že je tahle adresa v konzoli zapsaná, je ověřené: ručně sestavená adresa
souhlasu s ní došla 21. 8. až k výběru účtu.

**Tyhle opravy nejsou nasazené, dokud se necommitnou a nepushnou.** Oprava
GitHub secretu spravila Client ID v nasazeném buildu, ale `Env` se mění
v `lib/**`, takže se to na Pages dostane až dalším pushem.
