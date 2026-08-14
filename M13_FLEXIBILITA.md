# M13 — Flexibilní tvorba výletů a meeting mód

Návrh z 13. srpna 2026. Reaguje na čtyři zjištění z praktického testování: zadané
údaje nejdou přepsat, délka výletu je uzavřená do „1 / 2 / 3+ dny", místo konání
neumí víc než jeden cíl, a chybí režim pro čistou organizaci schůzky.

Dokument je rozdělený na tři etapy podle rizika. Etapa 1 je malá a nezávislá na
zbytku, etapa 2 sahá do plánovače dopravy a nákladů, etapa 3 je jen Flutter.
Pořadí není doporučení — etapa 2 stojí na sloupci, který zavádí etapa 1.

---

## 0. Co je potřeba udělat dřív

Tahle migrace bude **sedmá nenahraná v pořadí**. Šest migrací z M8 a databáze
zastávek nikdy neběželo (`VERIFY.md`). Když se M13 přidá na hromadu a `db push`
spadne, nepůjde poznat která z nich to byla.

Před `supabase db push` s M13 tedy: projet `VERIFY.md`, aplikovat M8 a zastávky,
spustit tři SQL testy. Teprve pak M13.

---

## 1. Délka: jedno pole místo tří

### Co je dnes

Model už dvě granularity umí — `granularity` (`day`/`time`), `duration_days`
(1–14) a `slot_minutes` (15–1440). To není špatný návrh; problém je, že jsou to
tři pole, uživatel mezi nimi přepíná ručně přes segment „Celý den / Pár hodin",
a formulář nabízí jen `1 / 2 / 3+ dny` a osm pevných délek do šesti hodin.
Dovolená na deset dní se založit nedá, přestože databáze by ji unesla.

### Co se mění

Zdrojem pravdy je nově **`duration_minutes`** (15 minut až 30 dní). Ostatní tři
sloupce z něj odvozuje `BEFORE INSERT OR UPDATE` trigger:

| sloupec | odvození |
|---|---|
| `duration_days` | `ceil(duration_minutes / 1440)` |
| `granularity` | `duration_minutes < 1440 → 'time'`, jinak `'day'` |
| `slot_minutes` | `duration_minutes` v time módu, jinak `null` |

**Proč trigger a ne přepsání všech konzumentů.** `duration_days` čte devět
funkcí — `trip_candidates`, `_weather_score`, `estimate_trip_cost`,
`packing_list` a `packing_rules.min_days/max_days`. Kdyby se sloupec zrušil,
mění se všechny najednou a naslepo. Takhle zůstávají beze změny a dál čtou
sloupec, který má pořád stejný význam — jen ho nikdo nezapisuje ručně.
`granularity` a `slot_minutes` totéž pro `trip_candidates` a `lock_trip_slot`.

**Proč odvozovat granularitu místo aby ji volil uživatel.** Volba „Celý den vs.
Pár hodin" je otázka na implementaci, ne na záměr. Kdo řekne „na tři hodiny",
už tím odpověděl. Zůstává jedna otázka místo dvou a jeden nekonzistentní stav
míň (dnes jde založit denní výlet se `slot_minutes`, které nic nedělají).

Zpětná kompatibilita dat je úplná: denní výlet s `duration_days = 1` dostane
1440 minut a vyjde z triggeru identicky, časový se `slot_minutes = 360` dostane
360 a zůstane v time módu. Žádný existující výlet nemění význam.

**Co to nemění.** Počasí se dál skóruje po dnech. U akce kratší než den se
skóruje den, do kterého spadne — jemnější rozlišení by předstíralo přesnost,
kterou předpověď na šest týdnů dopředu nemá.

### UI

Segment „Celý den / Pár hodin" mizí. Nahradí ho jeden řádek **Jak dlouho** se
sheetem: rychlé volby (30 min · 1 h · 2 h · půl dne · 1 den · víkend · týden)
a pod nimi vlastní hodnota. Pole „po kolika minutách nabízet začátky" a „v kolik
to připadá v úvahu" se ukazují jen pod 24 hodin, kde dávají smysl.

Strop 42 dní pro okno v time módu zůstává a hlásí se stejně jako dnes.

---

## 2. Editace po vytvoření

### Klíčové zjištění

Editace je dnes skoro zadarmo a nebude to platit dlouho. Plán, náklady i balení
jsou **čtecí funkce**, ne uložené řádky — `transport_options()`,
`estimate_trip_cost()`, `packing_list()` se počítají při každém otevření
záložky. Jediný uložený odvozený stav jsou **hlasy** (`date_votes`) a **zámek**
(`trips.locked_range`).

Jakmile vznikne Engine plánovač z M8 a začne ukládat `itineraries`, přibude
třetí. Editaci je proto správné postavit teď, dokud má dvě závislosti, a ne
později, až jich bude pět.

### `update_trip(p_trip uuid, p_patch jsonb)`

Jedna RPC pro všechna pole, patch sémantika: **klíč chybí = neměnit, klíč s JSON
null = vymazat**. Bez toho by nešlo rozlišit „nesahej na rozpočet" od „rozpočet
zruš" — což je přesně ta věc, kterou by API s nullable parametry tiše spletlo.

Vedlejší efekt, který se vyplatí: konec s dropováním přetížení. `create_trip` má
dnes devatenáct parametrů, každý přírůstek znamená `drop function` s přesnou
signaturou a s ním padá i `grant` (past ze session 2). `create_trip` se proto
mění taky na jeden `jsonb` argument. Další pole už nikdy nezmění signaturu.

### Pravidla invalidace

| změna | důsledek |
|---|---|
| okno se zúží | hlasy pro termíny mimo nové okno se smažou, ostatní zůstanou |
| délka se změní uvnitř téhož módu | hlasy zůstávají, zámek se protáhne/zkrátí od stejného začátku |
| délka přeskočí hranici 24 h | hlasy se smažou — mřížka kandidátů je jiná |
| změní se krok slotů | hlasy se smažou ze stejného důvodu |
| zámek přestane zasahovat do okna | zámek se zruší, stav zpátky na `planning` |
| aktivity, cíl, rozpočet, doprava | nic se nemaže, přepočítá se to samo při čtení |

Organizátor uvidí před uložením, co se rozpadne. Hlášku skládá klient
z porovnání starých a nových hodnot; server ji nevrací, protože v tu chvíli už
je pozdě.

Editovat smí jen organizátor — `is_trip_organiser` uvnitř funkce, ne jen RLS
politika, protože `security definer` ji obchází.

### UI

`CreateTripScreen` se rozpadne na `TripFormFields` (bezstavové pole + callbacky)
a dvě obrazovky nad ním: `CreateTripScreen` a `EditTripScreen`. Jedna sada polí,
dvě tlačítka. Vstup do editace je z `TripDetailScreen`, viditelný jen
organizátorovi.

---

## 3. Etapy cesty (`trip_legs`)

### Proč tabulka a ne výčet typů

Uživatel nemá vybírat „zájezd / delší cesta / dovolená". Vybírá zastávky a počet
nocí; typ z toho vyplyne. Tři pojmenované typy by znamenaly tři větve v každé
funkci a čtvrtý případ, který se do nich nevejde, přijde do měsíce.

```sql
create table trip_legs (
  id             uuid primary key,
  trip_id        uuid not null references trips on delete cascade,
  seq            int  not null,              -- 1..n, pořadí cesty
  label          text not null,
  destination_id uuid references destinations,   -- kurátorovaný cíl
  place_id       uuid references transit_places, -- zastávka pro MOTIS
  point          geography(point, 4326),
  nights         int  not null default 0 check (nights between 0 and 30),
  notes          text,
  unique (trip_id, seq)
);
```

Kombinace, které z toho vyjdou samy:

- **jednodenní zájezd** — 1 etapa, 0 nocí
- **pobyt na místě** — 1 etapa, N nocí
- **přejíždění** — N etap, každá s vlastním počtem nocí
- **cíl zatím neurčený** — 0 etap; tenhle stav je produktová featura, ne chyba

### Vztah k délce

Dva zdroje pravdy o délce výletu jsou past. Autoritativní zůstává
`duration_minutes` — protože výlet bez cíle nemá etapy a délku mít musí.
`sum(nights)` je pak validace, ne definice: server odmítne uložit etapy, jejichž
noci se do délky nevejdou. Formulář délku dopočítá při přidání etapy sám, ale
uživatel ji může přepsat.

### Co se musí přepsat

`trips.destination_id`, `destination_free`, `destination_point`,
`destination_place_id` se ruší a jejich obsah se stěhuje do `trip_legs` jako
etapa 1. Držet obojí by znamenalo dvě odpovědi na otázku „kam se jede".

Tím se mění tři funkce:

- `transport_options()` — dnes jedna cesta odkud→kam. Nově sekvence
  `origin → leg 1 → … → leg n → origin`, každý úsek zvlášť, součet nahoře.
- `estimate_trip_cost()` — doprava se sečte přes úseky, vstupné přes etapy
  s `destination_id`, nocleh podle `sum(nights)`.
- `_trip_weather_point()` — dnes jeden bod. Nově bod etapy s nejvíc nocemi,
  protože počasí rozhoduje o tom, kde se stráví většina času. U jednodenní
  cesty to vyjde na stejný bod jako dnes.

Tohle je jediná část M13, která sahá na už ověřený běžící kód. Proto je
poslední.

---

## 4. Meeting mód

`trips.kind` = `'trip' | 'meeting'`. Stejná tabulka, stejné pozvánky, stejné
sdílení kalendáře, stejný solver, stejné hlasování a zamykání.

Meeting je výlet, kterému chybí místo. Vypíná se: původ, etapy, doprava, počasí,
náklady, balení a aktivity. Zůstává: název, okno, **jak dlouho**, použitelná
část dne, krok slotů — a odkaz na sdílení kalendáře.

Vynucené schématem, ne jen UI:

```sql
check (kind = 'meeting' or origin_point is not null)          -- výlet má původ
check (kind = 'trip'    or destination_id is null and …)      -- meeting nemá cíl
```

`origin_point` a `origin_label` proto přestávají být `not null`. Ta podmínka se
tím nezeslabuje, jen se přesouvá tam, kde platí.

`_trip_weather_point()` vrací pro meeting nula řádků. Bez toho by tři `null`
souřadnice prošly jako platný bod a Termíny by ukazovaly skóre počasí pro
místo, které neexistuje.

`preview_invite()` vracelo `origin_label` bez ohledu na druh a klient ho
přetypovával na `String`. U setkání je null, takže by spadla jediná obrazovka,
kterou vidí nepřihlášený člověk z odkazu ve skupinovém chatu. Funkce teď vrací
i `kind` a `duration_minutes` a náhled u setkání ukazuje délku místo odjezdu.

Detail meetingu má dvě záložky místo pěti (Termíny, Lidé). Seznam výletů je
rozlišuje ikonou, ne oddílem — dva seznamy by znamenaly dvě prázdné obrazovky.

Meeting je celý v Engine módu. Žádná jeho část se nedotýká AI, takže na strop
€5/měsíc nemá vliv.

---

## 5. Pořadí a co v které etapě spadne

**M13.1 — schéma a editace** — napsáno, nespuštěno
(`20260813090000_m13_flexible.sql`) `duration_minutes` + trigger, `kind`,
`create_trip(jsonb)`, `update_trip(jsonb)`, `preview_invite` s druhem
a délkou, přepsaný `trips_list`. Nesahá na `trip_candidates`,
`transport_options` ani `estimate_trip_cost`. Riziko: trigger, který přepíše
`duration_days` u řádku, kde na něj něco spoléhá — proto backfill
`update trips set duration_minutes = duration_minutes` a kontrola, že se
hodnoty nepohnuly.

**M13.3 — Flutter** — napsáno, nespuštěno
`Trip` drží `durationMinutes` a `kind`; `durationDays`, `granularity`
i `slotMinutes` jsou z něj odvozené gettery, tedy tatáž trojice jako v triggeru
a na jednom místě. `TripDraft` je stav formuláře pro obě obrazovky a umí
`toNewTrip()`, `patchFrom(trip)` a `warningsAgainst(trip)`. `TripFormFields`,
`DurationField` (sheet s předvolbami i vlastní hodnotou), `EditTripScreen`,
`UpdateTripController` + `invalidateTripDerived`, výběr Výlet/Setkání nad FAB,
tři záložky u setkání místo šesti.

**M13.2 — etapy** — nezačato
`trip_legs`, přesun cíle, přepis `transport_options`, `estimate_trip_cost`,
`_trip_weather_point`. Nejrizikovější část, protože jako jediná sahá na kód,
který na telefonu prokazatelně běží; chce vlastní SQL test dřív než Flutter.

Pořadí spuštění: `VERIFY.md` → `supabase db push` → `flexible_test.sql` →
`dart format lib test` → `flutter analyze --fatal-infos` → `flutter test`.
Nic z M13 zatím neprošlo ani jedním z těch kroků.

Testy, které mají vzniknout se schématem, ne po něm:

- `duration_test.sql` — trigger odvodí správně na hranicích 15 / 1439 / 1440 /
  43200 minut
- `update_trip_test.sql` — zúžení okna smaže právě ty hlasy, co má; přeskok
  hranice 24 h smaže všechny; ne-organizátor dostane 42501
- `meeting_test.sql` — meeting bez původu projde, výlet bez původu ne, meeting
  s cílem ne
- všechny běží po `set local role authenticated`, jinak jsou granty neviditelné
