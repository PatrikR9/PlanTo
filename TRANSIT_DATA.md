# Data o dopravě — zdroje, licence, komerční užití

Ověřeno 8. srpna 2026. Doprovází migrace `20260808090000_transit_stops.sql`
a `20260808100000_transport_search.sql` a tabulku `feed_licences`, která je
provozní verzí tohohle dokumentu: feed bez řádku v ní se neimportuje.

Tenhle soubor odpovídá na jedinou otázku, kterou registr závislostí klade
každé službě: **můžu to používat v den, kdy si vezmu první euro?**

---

## Shrnutí

| Zdroj | Co dává | Licence | Komerčně | Atribuce |
|---|---|---|---|---|
| CIS JŘ / JDF | všechny linkové autobusy v ČR | volné dílo | ✅ | není nutná |
| CZPTT → GTFS | všechny vlaky v ČR | CC0-1.0 | ✅ | není nutná |
| PID | Praha + Střední Čechy, všechny druhy | CC BY 4.0 | ✅ | **povinná** |
| regionální IDS | MHD v krajích | per feed | ⚠️ ověřit | per feed |
| MOTIS (software) | routing engine | MIT | ✅ | není nutná |
| Transitous (služba) | hostovaný MOTIS | komunitní | ❌ | — |
| OpenStreetMap | zastávky | ODbL | ⚠️ share-alike | povinná |
| CHAPS KOMPLET / IDOS | jízdní řády | vlastnická | ❌ | — |

Dvě věci, které z toho plynou a nejsou zřejmé:

**Databáze zastávek a vyhledávač spojení jsou dva různé problémy s dvěma
různými licencemi.** Zastávky jsou CC0 nebo CC BY, dají se stáhnout a uložit
do Supabase a nic nestojí — ani teď, ani po prvním euru. Routing potřebuje
běžící MOTIS, tedy server. To je jediná část M7, která něco stojí, a jde
odložit.

**Free tier a nekomerční licence nejsou totéž.** Devět služeb v registru
nákladů je zdarma, ale nekomerčně. Zastávková data mezi ně nepatří — a to je
důvod, proč M7 vůbec šla udělat teď a ne až po monetizaci.

---

## 1. CIS JŘ / JDF — autobusy

- **Vydavatel:** Ministerstvo dopravy ČR, provozuje CHAPS spol. s r.o.
- **Data:** <https://portal.cisjr.cz/pub/JDF/JDF.zip>
- **Katalog:** [NKOD, „Jízdní řády veřejné linkové dopravy"][nkod]
- **Aktualizace:** třikrát týdně
- **Licence:** NKOD u distribuce výslovně uvádí *není autorským dílem* a
  *není chráněna zvláštním právem pořizovatele databáze*.

Volné dílo. Komerční užití, redistribuce i cachování bez podmínek a bez
povinné atribuce. Uvádět zdroj přesto budeme — je to slušnost a zároveň to
uživateli říká, odkud čísla jsou.

**Háček:** JDF nenese souřadnice zastávek, jen jejich názvy a správní
zařazení. Samotné JDF tedy nestačí — proto se importuje jeho GTFS konverze
(§4) a JDF zůstává záložním zdrojem názvosloví.

**Pozor na metadata:** distribuce je v NKOD označená jako *obsahuje osobní
údaje*. JDF nese kontakty na dopravce. Importér z něj bere jenom zastávky;
nic osobního se do PlanTo nedostane a ani nesmí.

## 2. CZPTT — vlaky

- **Data:** Správa železnic, formát CZPTT (XML), konverze do GTFS na
  <https://data.jr.ggu.cz/results/latest/CZPTT_GTFS.zip>
- **Licence:** CC0-1.0, jak ji deklaruje registr feedů projektu Transitous
- **Aktualizace:** denně

CC0 znamená vzdání se práv — komerční užití bez podmínek a bez atribuce.

**Otevřená položka:** licenci deklaruje registr Transitous, ne provozovatel
konverze na vlastním webu. Primární data od SŽ otevřená jsou; u konverze to
chce před prvním eurem potvrdit přímo a poznámku v `feed_licences` přepsat.
Kdyby to nevyšlo, náhrada je vlastní konverze CZPTT XML — víc práce, stejný
výsledek, žádná nová závislost.

## 3. PID — Praha a Střední Čechy

- **Data:** <https://data.pid.cz/PID_GTFS.zip>,
  stop list <https://data.pid.cz/stops/json/stops.json>
- **Licence:** [CC BY 4.0][ccby] (uvedeno na <https://pid.cz/o-systemu/opendata/>)
- **Aktualizace:** denně

Komerční užití povolené. **Atribuce je podmínka, ne doporučení:** uvést
autora a odkaz na licenci, a označit provedené změny. Text drží
`feed_licences.attribution` a obrazovka „O aplikaci" ho vypisuje přes
`transit_attributions()` — seznam se tak nemůže rozejít s tím, co je opravdu
naimportované.

PID je jediný zdroj, který k zastávce publikuje obec, okres, IDOS název a
příznak vlak/ostatní. Pro svoje území je proto autoritativní; jinde okres
prostě nemáme a hledání to musí unést (a unese — místa se shlukují podle
polohy, ne podle správního zařazení).

Web upozorňuje, že data jsou „náhled bez záruky" a formát se může změnit bez
ohlášení. Importér s tím počítá: neznámý tvar stop listu je varování a
prázdný okres, ne spadlý import.

## 4. Regionální IDS

ODIS, IDS JMK, IDZK, PMDP, DPMO a další publikují GTFS samostatně, licence
se liší feed od feedu. Do `feeds.json` se přidávají jednotlivě a **až po
ověření licence** — `import_transit_stops()` odmítne feed, který nemá řádek
v `feed_licences`, takže se nedá omylem naimportovat něco neověřeného.

Aktuálně je pod `cisjr_jdf` importovaná agregovaná GTFS konverze JDF
deklarovaná jako CC0. Je to komunitní rehost primárních dat, která sama
volná jsou; před prvním eurem patří ověřit i tuhle konverzi, nebo ji nahradit
vlastním JDF parserem.

## 5. Co se nepoužívá a proč

**OpenStreetMap** — ODbL. Vytáhnout z OSM kurátorovanou tabulku zastávek z ní
udělá *Derivative Database* se share-alike povinností: museli bychom pod ODbL
zveřejnit celou výslednou databázi. Past už jednou zapsaná v registru u
tabulky destinací; platí tady stejně.

**tangero/jizdni-rady-czech-republic** — agregovaný GTFS pro ČR deklarovaný
jako CC BY 4.0. Nepoužíváme ze dvou důvodů. Za prvé vzniká konverzí
`KOMPLET.ZIP` z IDOS, což jsou vlastnická data společnosti CHAPS, a přelicencovat
cizí data na CC BY nejde. Za druhé má všechny zastávky na souřadnicích
`0.0, 0.0`, takže by k ničemu nebyl ani kdyby licence seděla.

**Transitous** jako služba — komunitní hostovaný MOTIS bez komerční licence.
Použitelný pro vývoj, ne pro produkci. Software MOTIS sám je MIT a self-hosting
je povolený.

**Nominatim (veřejný)** — usage policy zakazuje přesně tenhle typ
interaktivního dohledávání. Geokodér je proto MOTIS, až poběží; do té doby
se hledá výhradně v naší tabulce zastávek.

---

## 6. Routing: co to stojí

Zastávky nestojí nic a stát nebudou. Vyhledávání spojení potřebuje běžící
MOTIS a to je jediná položka M7 s cenovkou.

| Varianta | Cena | Komerčně | Poznámka |
|---|---|---|---|
| geometrický odhad (dnes) | 0 | ✅ | žádný jízdní řád, časy jsou odhad |
| Transitous | 0 | ❌ | jen vývoj, nikdy produkce |
| vlastní MOTIS na VPS | ~4,5 €/měs | ✅ | Hetzner CX22, ~8 GB RAM na ČR |

Proto je poskytovatel v `app_config.transport_provider` a ne v kódu: dokud
je tam `estimate`, produkt funguje přesně jako dosud a nic se neplatí.
Přepnutí na `motis` je jeden `update` — ne deploy, ne refaktoring. Adaptér i
normalizace už existují a jsou otestované na vymyšlené odpovědi; první běh
proti skutečné instanci je potvrdí nebo opraví.

**Doplněno 24. 8. 2026 (M15).** Vedle `motis` je teď i poskytovatel
`transitous` — stejné API, jiná URL, a **jenom pro vývoj**: řádek v tabulce
výš se nezměnil, komerční licenci Transitous pořád nemá. Zapnutí je vědomý
`update app_config`, výchozí hodnota zůstává `estimate`. Endpoint je
`/api/{verze}/plan` (aktuálně `v6`, verze je v `app_config.motis_api_version`
a funkce na 404 zkusí starší). Transitous vyžaduje **User-Agent s kontaktem**
(`app_config.transport_user_agent`) a **viditelný odkaz na
<https://transitous.org/sources/>** (`app_config.transport_attribution`) —
text jde s odpovědí serveru, takže se nedá zapnout poskytovatel a zapomenout
na atribuci. Podrobnosti v `M15_PLAN_CASOVA_OSA.md`.

Jízdné ani po zapnutí MOTISu přesné nebude — přesné ceny české veřejné
dopravy nevydává zadarmo nikdo. Zůstává tarifní model v `fare_rules`,
označený jako odhad, s `confidence` a s odkazem na oficiální nákup.

---

## 7. Před prvním eurem

Doplněk k „day one of revenue" checklistu v registru nákladů:

- [ ] Ověřit licenci CZPTT konverze přímo u provozovatele a přepsat
      `feed_licences.notes`
- [ ] Totéž pro JDF → GTFS konverzi, nebo ji nahradit vlastním parserem
- [ ] MOTIS na vlastním serveru, `transport_provider` = `motis`,
      Transitous nikde v produkční konfiguraci
- [ ] Obrazovka s atribucemi obsahuje PID (a každý další CC BY feed)
- [ ] `checked_at` u všech řádků `feed_licences` mladší než rok

[nkod]: https://data.gov.cz/datov%C3%A1-sada?iri=https%3A%2F%2Fdata.gov.cz%2Fzdroj%2Fdatov%C3%A9-sady%2F66003008%2F1463646434
[ccby]: https://creativecommons.org/licenses/by/4.0/
