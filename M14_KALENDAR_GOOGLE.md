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
| Flutter: tlačítko, callback routa, `/calendar-callback` | napsáno, nespuštěno |
| Google Cloud projekt a klient | **na tobě** |
| `GOOGLE_CALENDAR_CLIENT_ID` do `env/dev.json` a repo secrets | **na tobě** |

Prázdné client ID tlačítko schová — to je záměr, ne obrana. Tlačítko, které
skončí na chybové stránce Googlu, stojí víc důvěry než tlačítko, které tam
není.

## 7. Past, do které jsem tě poslal

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
