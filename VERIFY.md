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
