# Ověřovací průchod

Nic z M5–M7 nikdy neběželo. Tenhle soubor je pořadí, ve kterém to spustit, a
co znamená, když každý krok spadne. Až projde celý, smaž ho — je to checklist,
ne dokumentace.

Pořadí není libovolné: každý krok je levnější než ten další a odhalí jiný druh
chyby. Databáze jde před aplikací, protože aplikace se ptá databáze na věci,
které tam ještě nemusí být.

## Jak to čteme spolu

Každý příkaz zapisuje výstup do `_logs/`. Ta složka je v `.gitignore` a je
uvnitř repozitáře, ke kterému mám přístup — takže **nic nekopíruj do chatu**.
Spustíš, řekneš „hotovo" a já si soubor přečtu sám, celý, včetně toho, co je
na řádku 200.

Do terminálu psát nemůžu (VS Code je povolený jen na klikání), takže příkazy
pouštíš ty. Tohle je způsob, jak z toho udělat jedno kolo místo tří.

```powershell
mkdir -Force _logs | Out-Null
```

---

## 1. Dart — kompilace a testy

```powershell
flutter pub get                                  2>&1 | Tee-Object _logs/1_pubget.txt
dart fix --apply ; dart format lib test          2>&1 | Tee-Object _logs/1_format.txt
flutter analyze --fatal-infos                    2>&1 | Tee-Object _logs/1_analyze.txt
flutter test                                     2>&1 | Tee-Object _logs/1_test.txt
```

`flutter pub get` je první, protože `url_launcher` je nová závislost.

Když `analyze` spadne, čekej chyby ze session 2 typu chybějící čárka nebo
dvakrát deklarovaná proměnná — obojí už se stalo.

## 2. Edge Functions — ICS parser

```powershell
deno check supabase/functions/**/*.ts   2>&1 | Tee-Object _logs/2_check.txt
deno test supabase/functions/_shared/   2>&1 | Tee-Object _logs/2_test.txt
```

Parser rozhoduje, jestli je někdo nahlášený jako volný, když volný není. To je
druh chyby, kterou skupina objeví na nástupišti.

## 3. Databáze — migrace

```powershell
supabase db push 2>&1 | Tee-Object _logs/3_push.txt
```

Sem jde pět nových migrací. Když to spadne, `supabase db push` vypíše celou
funkci a hlásí jen „failed to execute statement" — vypadá to jako syntaktická
chyba, ale nejčastěji to je něco z těchto tří:

| Symptom | Skutečná příčina |
|---|---|
| „cannot change return type of existing function" | `CREATE OR REPLACE` u `RETURNS TABLE`, které přibyl sloupec. Potřebuje `DROP FUNCTION` a znovu `GRANT EXECUTE` |
| „function is not unique" | Parametr s `DEFAULT` udělal přetížení, ne náhradu. Dropni starou signaturu ve stejné migraci |
| view vrací všechno / nic | Chybí `security_invoker = true` |

## 4. Databáze — SQL testy

```powershell
Get-ChildItem supabase/tests/*.sql | ForEach-Object {
  psql "$env:DB_URL" -v ON_ERROR_STOP=1 -f $_.FullName 2>&1 |
    Tee-Object -Append _logs/4_sqltests.txt
}
```

## 5. Edge Functions — nasazení

```powershell
supabase secrets set ICAL_SECRET="<něco dlouhého a náhodného>"
supabase functions deploy weather
supabase functions deploy ical-sync
```

Bez `ICAL_SECRET` iCal cesta nemá čím šifrovat a funkce to řekne rovnou —
`errorText()` tu hlášku teď propustí až na obrazovku.

## 6. Dashboard — než začneš klikat v aplikaci

Tohle není kód a nespraví se to opakováním. Čtyři přepínače:

- Authentication → Providers → **Anonymous sign-ins ON**
- Authentication → Providers → **Email ON**
- Authentication → URL Configuration → Site URL a Redirect URLs na Pages
  adresu a `http://localhost:50350`
- Settings → Secrets and variables → Actions → `SUPABASE_URL`,
  `SUPABASE_ANON_KEY` (bere je Flutter build **i** pozvánková stránka)
- Settings → Pages → Source → **GitHub Actions**

## 7. Telefon

Emulátor stačí — kalendář na něm je prázdný, ale `CalendarProvider` je tam
stejný, a bod 3 níž selhává na oprávnění a channelu, ne na datech. Na reálném
telefonu se to zopakuje až kvůli opakujícím se událostem.

```powershell
flutter run --dart-define-from-file=env/dev.json 2>&1 | Tee-Object _logs/7_run.txt
```

Pro APK do telefonu `.\tool\build_apk.ps1`. Ten skript existuje kvůli
`--dart-define-from-file`: bez něj se `String.fromEnvironment` vyhodnotí při
kompilaci na prázdné řetězce a APK je natrvalo bez konfigurace — a hlásí to
jako chybějící soubor, který tam je.

Pak, v tomhle pořadí:

1. Přihlásit se jako host
2. Založit výlet
3. **Sdílet dostupnost → povolit kalendář.** Tohle je jediná věc, která může
   celý produkt zabít, a hlásí se jako rozbitá. Log z běhu je už v
   `_logs/7_run.txt`, takže stačí říct, u kterého kroku to spadlo.
4. Záložka Termíny: heatmapa, kandidáti, skóre počasí
5. Nastavit cíl → záložka Plán: vzdálenost, čas, cena, odkaz do IDOS
6. Otevřít pozvánkový odkaz v prohlížeči bez nainstalované aplikace

Body 1–6 můžu proklikat sám, když povolíš emulátor jako aplikaci — dialog
minule vypršel. Pak `flutter run` necháš běžet a zbytek udělám já, včetně
screenshotů toho, co se rozbilo.

---

Co se **neověří** ničím z tohohle: jestli jsou názvy proměnných z Open-Meteo
správně (§14 položka 7). Pozná se to až tím, že skóre počasí vyjde `null` na
dnech, které jsou v předpovědi.

---

# M7 — zastávky a spojení (session 4)

Pořadí je tady důležitější než jinde: dokud neproběhne import, hledání
zastávek legitimně nic nevrací a **nejde založit výlet** (výchozí bod je od
téhle session povinná zastávka). Aplikace to sama pozná a napíše „databáze
zastávek zatím není naimportovaná" místo „nic jsme nenašli" — ale spustit
import je stejně první věc.

## M7.1 Migrace

```powershell
supabase db push 2>&1 | Tee-Object _logs/m7_1_push.txt
```

Přibývají dvě: `20260808090000_transit_stops.sql` a
`20260808100000_transport_search.sql`.

Když to spadne, nejpravděpodobnější příčiny v tomhle pořadí:

- `create_trip` se dropuje a vytváří znovu kvůli novému parametru. Když
  hlásí nejednoznačnost, drop signatury nesedí na to, co je v databázi —
  vypiš `\df create_trip` a porovnej.
- `st_clusterdbscan` chybí ve staré PostGIS. Vyžaduje 2.3+; Supabase má 3.x,
  takže by to nemělo nastat.
- `trips_list` se dropuje a vytváří znovu (přibývají dva sloupce uprostřed).

## M7.2 Import zastávek

Potřebuje service_role connection string, ne anon klíč. Vezmi ho ze
Supabase → Settings → Database → Connection string → URI.

```powershell
pip install "psycopg[binary]"
python tool/transit_import/import_stops.py --db "<DB_URL>" 2>&1 | Tee-Object _logs/m7_2_import.txt
```

Stáhne se kolem 300 MB a poběží to jednotky minut. Očekávaný výsledek jsou
desítky tisíc zastávek a nižší desítky tisíc míst — když vyjde řádově míň,
něco se zaparsovalo špatně a **nepokračuj**, protože další běh by rozdíl
označil jako zrušené zastávky.

Opakované spuštění je bezpečné: import je idempotentní a nemaže, označuje.
Pro rychlé opakování bez stahování `--skip-download`.

## M7.3 SQL testy

```powershell
psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/transit_stops_test.sql 2>&1 | Tee-Object _logs/m7_3_sql.txt
```

Běží jako `authenticated`, takže chyba v grantech se projeví. Celé to je
v transakci s `rollback` na konci — testovací data v databázi nezůstávají.

## M7.4 Edge Functions

```powershell
deno check supabase/functions/**/*.ts        2>&1 | Tee-Object _logs/m7_4_check.txt
deno test supabase/functions/_shared/        2>&1 | Tee-Object _logs/m7_4_test.txt
supabase functions deploy transport-search   2>&1 | Tee-Object _logs/m7_4_deploy.txt
```

Testy pokrývají ranking, tarifní odhad, klíč do cache a normalizaci odpovědi
MOTISu — tedy všechno kromě samotného HTTP.

## M7.5 Flutter

```powershell
flutter analyze --fatal-infos 2>&1 | Tee-Object _logs/m7_5_analyze.txt
flutter test                  2>&1 | Tee-Object _logs/m7_5_test.txt
flutter run --dart-define-from-file=env/dev.json 2>&1 | Tee-Object _logs/m7_5_run.txt
```

Na zařízení, v tomhle pořadí:

1. Nový výlet → **Odkud jedete** → napsat `praha hl`. Musí přijít
   `Praha hl.n.` jako první, do půl sekundy.
2. Napsat `cerny most` bez diakritiky. Musí najít Černý Most.
3. Napsat `praha` a nechat být. Nesmí se nic vybrat samo.
4. Napsat `zlicin`, `adrspach`, `pisek` — malé obce musí být dohledatelné
   stejně jako krajská města.
5. Založit výlet a otevřít **Plán** → Změnit cíl. Stejný picker, a výsledky
   blíž k výchozí zastávce mají být výš.
6. Zkontrolovat, že Plán a Náklady pořád ukazují čísla — pod nimi je zatím
   pořád geometrický odhad a M7 ho nesmí rozbít.

## Co se tímhle neověří

`transport-search` s poskytovatelem `motis`. Ten adaptér je psaný proti
dokumentaci MOTIS v2 a nemá se zatím proti čemu spustit — dokud je
`app_config.transport_provider` = `estimate`, funkce vrací geometrický odhad
a MOTIS kód se nezavolá. Pozná se to až prvním během proti vlastní instanci;
normalizace je proto defenzivní a výpadek degraduje na odhad, ne na chybu.
