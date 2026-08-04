# Ověřovací průchod

Nic z M5–M7 nikdy neběželo. Tenhle soubor je pořadí, ve kterém to spustit, a
co znamená, když každý krok spadne. Až projde celý, smaž ho — je to checklist,
ne dokumentace.

Pořadí není libovolné: každý krok je levnější než ten další a odhalí jiný druh
chyby. Databáze jde před aplikací, protože aplikace se ptá databáze na věci,
které tam ještě nemusí být.

---

## 1. Dart — kompilace a testy

```powershell
flutter pub get
dart fix --apply ; dart format lib test
flutter analyze --fatal-infos
flutter test
```

`flutter pub get` je první, protože `url_launcher` je nová závislost.

Když `analyze` spadne, čekej chyby ze session 2 typu chybějící čárka nebo
dvakrát deklarovaná proměnná — obojí už se stalo. Pošli mi výstup celý, ne
první řádek.

## 2. Edge Functions — ICS parser

```powershell
deno check supabase/functions/**/*.ts
deno test supabase/functions/_shared/
```

Parser rozhoduje, jestli je někdo nahlášený jako volný, když volný není. To je
druh chyby, kterou skupina objeví na nástupišti.

## 3. Databáze — migrace

```powershell
supabase db push
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
psql "$env:DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/availability_test.sql
psql "$env:DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/dates_test.sql
psql "$env:DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/weather_test.sql
psql "$env:DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/transport_test.sql
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

```powershell
.\tool\build_apk.ps1
```

Ten skript existuje kvůli `--dart-define-from-file`. Bez něj se
`String.fromEnvironment` vyhodnotí při kompilaci na prázdné řetězce a APK je
natrvalo bez konfigurace — a hlásí to jako chybějící soubor, který tam je.

Pak, v tomhle pořadí:

1. Přihlásit se jako host
2. Založit výlet
3. **Sdílet dostupnost → povolit kalendář.** Tohle je jediná věc, která může
   celý produkt zabít, a hlásí se jako rozbitá. Když spadne, pošli
   `run_log.txt` — ne popis, log.
4. Záložka Termíny: heatmapa, kandidáti, skóre počasí
5. Nastavit cíl → záložka Plán: vzdálenost, čas, cena, odkaz do IDOS
6. Otevřít pozvánkový odkaz v prohlížeči bez nainstalované aplikace

---

Co se **neověří** ničím z tohohle: jestli jsou názvy proměnných z Open-Meteo
správně (§14 položka 7). Pozná se to až tím, že skóre počasí vyjde `null` na
dnech, které jsou v předpovědi.
