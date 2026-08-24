# M15 — Plán jako interaktivní časová osa

**Napsáno 24. srpna 2026. Nespuštěno** — na straně asistenta není Flutter,
Dart, Deno ani databáze. Příkazy k ověření jsou v §10.

Záložka „Plán" byla dvě karty s odhadem vzdálenosti a ceny. Teď je to
chronologická osa celého výletu, kterou jde upravovat, a systém na úpravy
reaguje přepočtem **jenom té části, které se změna týká**.

---

## 1. Co je nové a kde to je

### Databáze — `supabase/migrations/20260824090000_plan_timeline.sql`

| Objekt | K čemu |
|---|---|
| `plan_item_kind`, `plan_item_source`, `plan_segment` | slovník osy |
| `itineraries` | plán: den, zadání (`arrive_by`, `home_by`), poskytovatel, revize |
| `itinerary_items` | položky osy včetně `source`, `is_locked`, `user_edited` |
| `trip_plan(p_trip)` | celý plán jako jeden jsonb, včetně **místních** časů |
| `save_trip_plan(p_trip, p_plan, p_revision)` | atomická výměna celého plánu |
| `reset_trip_plan(p_trip)` | zahození plánu (např. po odemčení termínu) |
| `trip_plan_context(p_trip)` | vstupy pro engine v jednom volání |

`itineraries` a `itinerary_items` jsou tabulky z architektury §9.5, rozšířené
o tři sloupce, bez kterých se replanning nedá dělat poctivě: `source`,
`is_locked`, `user_edited`. Bez nich je po znovunačtení výletu plán jenom
seznam časů.

### Edge Function — `supabase/functions/`

- `_shared/transport.ts` — opravená normalizace MOTISu proti skutečnému
  `openapi.yaml`, `motisTransitModes()`, `localIso()`, `withLocalTimes()`,
  `direction` v klíči do cache.
- `transport-search/index.ts` — poskytovatel `transitous` vedle `motis`,
  konfigurovatelná verze API s fallbackem, User-Agent, atribuce v odpovědi,
  místní časy, rozlišení „nic jsem nenašel" od „vyhledávač spadl".

### Flutter — `lib/features/planner/`

```
domain/     journey.dart        spojení nezávislé na poskytovateli
            plan_item.dart      položka osy + převody zóny
            trip_plan.dart      plán + zadání
            plan_problem.dart   kódy problémů
            plan_change.dart    sealed úpravy
            plan_context.dart   fakta o výletu, dotaz na spojení
            replanner.dart      engine (čistý, bez sítě)
data/       journey_repository.dart   volání Edge Function
            plan_repository.dart      trip_plan / save_trip_plan / kontext
presentation/ plan_controller.dart    orchestrace + ukládání
            plan_strings.dart         české věty a ikony
            screens/plan_tab.dart
            widgets/plan_timeline.dart, plan_item_sheet.dart,
                    journey_options_sheet.dart
```

Přesunuto, ne smazáno: výběr cíle a srovnání „vlakem versus autem" žijí
v `lib/features/transport/presentation/widgets/destination_card.dart` a
na nové ose jsou pořád. Původní `transport/presentation/screens/plan_tab.dart`
je v `_to_delete/planner-refactor/` (mount neumí mazat).

### Testy

- `supabase/functions/_shared/transport_test.ts` — +11 případů
- `test/plan_journey_test.dart` — parsování, místní časy, prázdný výsledek
- `test/plan_replanner_test.dart` — 20 případů přes celý engine
- `test/plan_fixtures.dart` — sdílená data

---

## 2. Architektura dopravy

```
UI / engine
    │  Journey, JourneyLeg, FareEstimate   ← nezná žádného poskytovatele
    ▼
JourneyRepository  (lib/features/planner/data)
    │  supabase.functions.invoke('transport-search')
    ▼
Edge Function transport-search
    ├── estimate    geometrie + tarifní model  (výchozí, €0, bez řádu)
    ├── transitous  komunitní MOTIS            (vývoj — viz §8)
    ├── motis       vlastní instance           (produkční cíl)
    └── normaliseMotis() → PlanTo model → tarif → CO₂ → ranking → cache
```

Klient nemluví s třetí stranou nikdy. Tím je „v aplikaci nejsou klíče"
vlastnost topologie, ne slib. Přepnutí poskytovatele je `update app_config
set value = '"motis"' where key = 'transport_provider'` — ne deploy.

Base URL není nikde v kódu: `transitous_url` je v `app_config`, vlastní MOTIS
čte `MOTIS_URL` z prostředí funkce (může nést token).

---

## 3. Transitous / MOTIS — co přesně se volá

Ověřeno 24. 8. 2026 proti `motis-project/motis` `openapi.yaml` a
<https://transitous.org/api/>.

- **Endpoint:** `GET {base}/api/{verze}/plan`, aktuálně `v6`. Verze je
  v `app_config.motis_api_version`; na 404 funkce zkusí v6→v1 a nalezenou si
  zapamatuje do konce běhu isolate. Natvrdo `v1` je přesně to, co se jednou
  tiše rozbije.
- **Parametry:** `fromPlace`, `toPlace` (souřadnice — naše UUID zastávky pro
  MOTIS nic neznamená), `time`, `arriveBy`, `numItineraries`, `transitModes`,
  volitelně `maxTransfers`.
- **Odpověď:** `itineraries[].{duration (s), startTime, endTime, transfers,
  legs[]}`, leg `{mode, from, to, duration (s), startTime, endTime,
  scheduledStartTime, scheduledEndTime, realTime, distance (m), headsign,
  agencyName, routeShortName, routeLongName, displayName, tripId, cancelled,
  intermediateStops[]}`, Place `{name, stopId, lat, lon, track,
  scheduledTrack, arrival, departure, ...}`.

Opravené chyby proti dřívějšímu odhadu: `platformCode` neexistuje (je
`scheduledTrack`), `routeId` neexistuje, `duration` je v **sekundách**,
`CABLE_CAR` se nepíše `CABLECAR`, a `TROLLEYBUS` v enumu **není** — trolejbusy
chodí jako `BUS`, takže posílat ho v `transitModes` znamená 400 na celý dotaz.

Z odpovědi se bere: čas odjezdu a příjezdu, celková délka, jednotlivé úseky,
druh dopravy, linka a dopravce, nástupní a výstupní zastávka, nástupiště,
mezizastávky, plánovaný čas (a tedy zpoždění) a příznak realtime. Počet
přestupů a délka čekání se **počítají** z časů, nepřenášejí — druhé číslo
o téže věci je jenom příležitost, aby se ta dvě rozešla.

Zrušené spoje (`cancelled`) se zahazují. Poslat někoho na zrušený vlak je
horší než neposlat nic.

---

## 4. Cache

Serverová, v `transport_cache`, klíč z `cacheKey()`:

```
v2 | provider | origin | destination | okno/15 min | dep|arr | direction | modes
```

Okno se zaokrouhluje na čtvrthodinu dolů: bez zaokrouhlení má každá sekunda
vlastní klíč a cache nikdy netrefí, se zaokrouhlením na hodinu by mohla minout
spoj, na který se někdo ptal. `direction` je v klíči i přes to, že ho
origin/destination odlišují — až přibude parametr, který se pro zpáteční cestu
liší, byl by bez něj výsledek sdílený mezi směry.

TTL je `app_config.transport_cache_ttl_min` (180 min). **Prázdný výsledek se
cachuje taky**, ale jen 30 minut — jinak každé otevření obrazovky vyrobí nový
dotaz na komunitní službu kvůli spojení, které neexistuje.

Selhání: timeout 12 s, chyba API, neplatná nebo prázdná odpověď → degradace na
geometrický odhad, nikdy pád. V odpovědi je `has_timetable: false` a
`provider_error`, takže obrazovka umí říct rozdíl mezi „časy jsou odhad" a
„časy jsou odhad, protože vyhledávač spadl". Když poskytovatel odpoví a nic
nenajde, vrátí se **prázdno** — geometrický odhad by tvrdil, že spoj existuje.

---

## 5. Interaktivní osa

Každý řádek je řádek v `itinerary_items`, ne widget. Druhy: `transport`,
`walk`, `transfer`, `activity`, `free`, `meal`, `accommodation`, `custom`.

Mezera mezi body se **nevykresluje jako položka**. Volno není věc, je to
nepřítomnost věcí; kdyby mělo řádek v databázi, engine by ho při každém posunu
přepočítával a uživatel by mazal prázdno. Místo toho je v mezeře nabídka
„Přidat bod".

Uživatel může: upravit čas a délku bodu, přejmenovat ho, přidat poznámku,
zamknout, odemknout, smazat (u dopravy ne — ta zmizí s přepočtem trasy, ne
tlačítkem), přidat vlastní bod, vybrat jiný spoj, nastavit „chci dorazit do"
a „chci být doma do".

Drag-and-drop záměrně není. Na ose s minutovým rozlišením je tažení prstem
hádání; „Začátek: 14:00" v dialogu je přesné a jde použít jednou rukou.

---

## 6. Replanning

Dva kroky, a to je celý trik:

1. `Replanner.needsFor(plan, change, ctx)` řekne, **které úseky** je potřeba
   dohledat. „Chci být doma do osmi" vrátí jenom cestu zpět.
2. `Replanner.apply(...)` dostane výsledky a plán přepočítá.

`ReplanOutcome.followUp` je požadavek na druhé kolo — vzniká, když se první
kolo dozví něco, co před vyhledáním vědět nemohlo (prodloužená aktivita už
nestíhá naplánovaný spoj domů). Kola jsou nejvýš dvě; třetí by znamenalo, že
se pravidla perou mezi sebou.

Kdo co spouští:

| Změna | Hledá se |
|---|---|
| „dorazit do X" | jen cesta tam (`arriveBy`) |
| „vyrazit po X" | jen cesta tam (`departAfter`) |
| „být doma do X" | jen cesta zpět (`arriveBy`) |
| posun/prodloužení programu | nic, dokud se vejde; pak jen cesta zpět |
| „jiný spoj" u úseku | jen ten úsek |

Cesta zpět je **vždy samostatný dotaz** z cíle do výchozího bodu, se svým
časem a svým `direction`. Otočit ranní itinerář by byl vymyšlený jízdní řád:
odpolední spoje jezdí jinak často a v neděli úplně jinak.

Preference při přepočtu: zamčené → ručně vybrané → ručně upravené → existující
aktivity → současný plán. Když je víc řešení, vyhrává to s nejmenší změnou.

---

## 7. Zamčené versus flexibilní

`is_locked` znamená „engine na to nesmí sáhnout". Vzniká zamčením od
uživatele, ručním výběrem spoje, nebo u rezervované aktivity.

- Zamčený bod se **nikdy** neposune. Když se na něj kvůli pozdějšímu příjezdu
  nestíhá, vrátí se `arrivalAfterActivity` — ne posunutý zámek.
- Ručně vybraný spoj se nevymění potichu. Kaskádová změna (posunul se program)
  ho nechá být a vrátí `lockedConflict`; změna zadání, se kterou nejde
  splnit (jiný deadline), ho vymění a vrátí `userChoiceReplaced`.
- Když je návrat zamčený a program mu přeroste, **zkrátí se program** — je to
  menší změna než vyměnit spoj, o kterém rozhodl člověk.
- Flexibilní body engine posouvá volně, `user_edited` se posune jen tehdy,
  když jinak není řešení, a vždycky se to zvýrazní na ose.

Program se **neseřazuje do fronty**: oběd uvnitř prohlídky je legitimní
překryv. Jediné pravidlo je „nic nezačne dřív, než skupina dorazí".

---

## 8. Ceny jízdenek

Beze změny proti M7 a schválně. Tarifní model v `fare_rules`, odhad jako
rozpětí, `confidence` z nejslabšího použitého pravidla, `isEstimate` je
**konstanta typu**, ne pole — přepnout ji na `false` by znamenalo, že se odhad
od ceny nepozná podle typu. Na obrazovce je u každé částky „odhad" a odkaz do
IDOS na skutečný nákup.

Přesné jízdné české veřejné dopravy zadarmo nevydává nikdo. AI se na cenu
neptá a ptát nebude.

---

## 9. Známé limity Transitousu

1. **Není komerčně licencovaný.** Komunitní služba (TRANSIT_DATA.md §5,
   registr nákladů C1). Použitelný pro vývoj a testování, do produkce patří
   vlastní MOTIS (software je MIT, ~4,5 €/měs na Hetzner CX22). Proto
   `transport_provider` zůstává `estimate` a zapnutí Transitousu je vědomý
   `update`, ne výchozí stav.
2. **Vyžaduje User-Agent** s názvem aplikace, verzí a kontaktem — je
   v `app_config.transport_user_agent`, opravit před prvním ostrým během.
3. **Vyžaduje viditelný odkaz** na <https://transitous.org/sources/>. Text je
   v `app_config.transport_attribution`, jde s odpovědí serveru a záložka ho
   vypisuje — nedá se zapnout poskytovatel a zapomenout na atribuci.
4. **Prosí o kontakt před větší zátěží.** Cache a polite usage jsou nutné, ne
   volitelné.
5. **Verze API se mění** bez ohlášení; proto fallback v6→v1.
6. **Pokrytí ČR závisí na feedech** v registru Transitousu. Regionální IDS
   nemusí být kompletní a MHD může chybět.
7. **Realtime data** jsou tam, kde je dodává dopravce — jinde je `realTime`
   false a zpoždění se nezobrazuje (ne nula: „nevíme" a „jede včas" nejsou
   totéž).
8. **Jízdné neposkytuje** v ČR prakticky nikdy.

---

## 10. Co je potřeba spustit

Nic z toho neproběhlo:

```bash
dart fix --apply && dart format lib test
flutter analyze --fatal-infos
flutter test
deno test supabase/functions/_shared/
supabase db push
supabase functions deploy transport-search
```

Zapnutí skutečných jízdních řádů (vývojově):

```sql
update app_config set value = '"transitous"' where key = 'transport_provider';
update app_config set value = '"PlanTo/0.1 (+https://planto.app; TVUJ@MAIL)"'
  where key = 'transport_user_agent';
```

Zpátky na odhad: `update app_config set value = '"estimate"' where key =
'transport_provider';`

## 11. Co se otestovalo

**Deno (`transport_test.ts`)** — normalizace celé odpovědi MOTISu se všemi
poli, trasa bez přestupu, dva přestupy, pěší úseky, zrušený spoj, prázdná i
poškozená odpověď, mapování druhů dopravy, `transitModes` (včetně trolejbusu
jako `BUS`), místní čas přes DST, klíč do cache (okno, směr, příjezd versus
odjezd), tarif a ranking (beze změny z M7).

**Dart (`plan_journey_test.dart`)** — parsování spojení, přestupy počítané
z časů, pěší úsek, jízdné jako rozpětí, zpoždění proti jízdnímu řádu, prázdný
výsledek versus výpadek poskytovatele, atribuce, převody časové zóny.

**Dart (`plan_replanner_test.dart`)** — sestavení osy z obou cest, přestup
jako vlastní položka, program mezi příjezdem a odjezdem, jízdné na spoji,
`has_timetable: false`, oddělené dotazy tam a zpět, „co se kvůli změně hledá
znovu" pro všechny čtyři druhy zadání, posun flexibilního programu, zamčený
program se nehne, ruční úprava přežije přepočet, zámek nic nemaže, minimální
nutná změna (cesta tam se nedotkne), zamčený návrat zkrátí program místo
výměny spoje, vlastní bod přepočet nesmaže, ručně vybraný spoj se nevymění
kaskádou a vymění se zadáním (s hláškou), nenalezený návrat s nejbližším
možným časem, nenalezená cesta tam plán nesmaže, pozdější příjezd než chtěný,
persistence celého stavu položky přes server, ID nové položky, výběr spoje
podle deadlinu.

**Neotestováno:** cokoli proti skutečné instanci MOTISu, SQL migrace proti
skutečné databázi, a chování UI. Testy API běží proti mockovaným odpovědím
schválně — test suite nesmí záviset na dostupnosti komunitní služby.


---

## 12. První běh CI (24. 8. 2026, commit 4bd3028)

Záložka „Plán" prošla líp, než se čekalo, a vypadly z toho dvě cizí chyby.

**Co prošlo:** `flutter test` — **120 testů zeleně**, včetně všech nových
(replanner, parsování spojení, persistence). `supabase db start` a `db lint`
prošly, takže **migrace 20260824090000 se aplikovala na skutečný Postgres**.
`deno test` — 31 z 34 případů v `transport_test.ts`.

**Co bylo z M15 a je opravené:**

- `flutter analyze --fatal-infos` hlásil 32 věcí, všechny `info` (chybějící
  čárky, jedno `prefer_final_locals`). Žádná chyba, žádný warning. Opraveno
  záplatou z CI a jedním `final`.
- `motisTransitModes()` vracela u plné sady čtyři hodnoty místo `TRANSIT`.
  Při opravě se ukázalo něco horšího: náš `bus` se mapoval jenom na `BUS`,
  jenže **dálkové autobusy jsou v MOTISu `COACH`** — RegioJet a FlixBus by
  z výsledků vypadly. Každý druh se teď rozvíjí na všechny hodnoty, které
  pokrývá.
- `deno check` neprošel na `transport-search/index.ts`: `createClient` vrací
  s options a bez nich dvě různé instanciace generik. Vyřešeno aliasem `Db`
  na jednom místě, s poznámkou, kam patří generovaný `Database` typ.

**Co bylo červené už před M15 a opravené je:**

- `transport_test.ts` čekal u trasy „pěší úsek + vlak + pěší úsek" délku
  52 minut. 07:00 → 09:52 je 172; 52 bylo číslo z ciferníku. Opraveno.
- Pět SQL testů padalo na `duplicate key ... profiles_pkey`. Příčina není
  sdílená databáze, jak to na první pohled vypadalo: trigger
  `on_auth_user_created` založí profil hned při vložení do `auth.users`,
  takže následný `insert into profiles` v témže souboru koliduje sám se
  sebou. Čtyři testy to už ošetřené měly (`on conflict do nothing`), pět ne.
  Doplněno — a tím se poprvé dostaly dál než na dvacátý řádek (§14).
- `google-calendar/index.ts` neprošel `deno check` kvůli
  `crypto.subtle.importKey("raw", …)` — od TypeScriptu 5.7 `Uint8Array` nad
  `ArrayBufferLike` nesedí do `BufferSource`. Kopie do čerstvého bufferu.

**Co je červené a nesahal jsem na to** (obojí je mimo M15 a obojí je skutečná
chyba, ne rozbitý test):

1. `rebuild_transit_places()` v migraci `20260808090000` zakládá
   `create temporary table _clust on commit drop`. Test ji volá dvakrát
   v jedné transakci, takže druhé volání spadne na „relation `_clust` already
   exists". Funkce není idempotentní uvnitř transakce; oprava je nová migrace
   s `create or replace` a `drop table if exists _clust` na začátku.
2. `ics_test.ts` — „a weekly rule expands inside the window only" čeká
   07:00Z a dostane 08:00Z. Týdenní RRULE se rozvíjí s pevným posunem od
   `DTSTART` místo v zóně, takže **přes přechod letního času vyjde termín
   o hodinu vedle**. To není kosmetika: je to dostupnost hlášená špatně.

## 13. Jak číst výsledky CI

`ci.yml` po každém běhu force-pushne report do větve `ci-report`:

    ci-report/summary.txt     výsledek každého jobu + commit
    ci-report/flutter.txt     format, analyze, test
    ci-report/database.txt    migrace, lint, SQL testy
    ci-report/functions.txt   deno check, deno test
    ci-report/fixes.patch     `dart fix --apply` + `dart format`, k aplikování

Záplata se aplikuje `git apply` v kořeni repozitáře. Větev je pokaždé jeden
commit z prázdné historie — neroste a nedá se z ní nic smergovat.


---

## 14. Třetí běh CI (commit d0d6924) — a co odkryl

    flutter:   success      analyze --fatal-infos: No issues found, 120 testů
    functions: failure      deno check ok, 46/47 (zbývá cizí DST chyba)
    database:  failure      migrace + lint ok, testy viz níž

Záložka Plán je z pohledu CI hotová: formátování, analyzátor ani testy nemají
co vytknout a `fixes.patch` chodí prázdná.

**SQL testy jsou zajímavější.** Oprava kolize profilů (§12) je pustila přes
setup a **teprve teď je vidět, na čem doopravdy padají**. Nic z toho nezpůsobil
M15 — jenom to do teď zakrývala chyba na dvacátém řádku:

| test | padá na | co to nejspíš je |
|---|---|---|
| `availability_test` | — | prochází |
| `busy_write_test:88` | `permission denied for table trip_participants` | chybějící `grant select` pro roli `authenticated` |
| `dates_test:107` | totéž | totéž |
| `flexible_test:150` | `permission denied for table trips` | totéž |
| `costs_test:115` | `jidlo neskaluje: 1 den = 150, 3 dny = 150` | **skutečná chyba v cenovém modelu** |
| `packing_test:161` | `celovka nechybi ani neni pri navratu za sera` | **skutečná chyba v pravidlech balení** |
| `transit_stops_test:162` | `relation "_clust" already exists` | `rebuild_transit_places()` není idempotentní v transakci |
| `transport_test`, `weather_test` | — | prochází |

Dvě z toho nejsou problémy testů: **jídlo se neškáluje s délkou výletu** a
**čelovka se nepřidá při návratu za šera**. Obojí jsou funkce, které uživatel
uvidí jako špatné číslo a chybějící věc v batohu.

Tři „permission denied" vypadají na chybějící grant: testy čtou `trips`
a `trip_participants` přímo pod rolí `authenticated`, zatímco aplikace k nim
chodí přes pohled `trips_list` a RPC. Buď testům chybí grant, nebo mají číst
totéž co aplikace — to je rozhodnutí, ne oprava.

**Co jsem v CI vrátil:** obalování každého testu do zahozené transakce.
Neopravilo to nic (kolize byla uvnitř souborů) a testy si `begin`/`rollback`
i `set local role` řídí samy — vnořený `begin` Postgres ignoruje. Vrstva,
která nic nepřináší a může mást, je horší než žádná.
