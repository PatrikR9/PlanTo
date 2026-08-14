# Přihlášení

> **Rozhodnutí z 9. srpna 2026: PlanTo zatím jede bez odesílání e-mailů.**
>
> Brevo se nepodařilo napojit. Supabase hlásilo 504 na každé cestě, která
> odesílá mail, v Brevu nebyl jediný záznam o pokusu o spojení, a `Send-Mail‑
> Message` přímo z počítače selhalo taky. To poslední je důležité: **vyloučilo
> to Supabase.** Chyba není v konfiguraci projektu, ale někde mezi účtem u
> Brevo a jeho SMTP branou.
>
> Místo dalšího hádání se přihlašování postavilo tak, aby e-mail nepotřebovalo.
> Není to provizorium — je to funkční stav, se kterým se dá jít i k testerům.

## Co funguje bez e-mailu

| | |
|---|---|
| Registrace heslem | ano, `Confirm email` musí být **OFF** |
| Přihlášení heslem | ano, nikdy mail nepotřebovalo |
| Pokračovat jako host | ano |
| Pozvánky do výletu | ano — jsou to odkazy do chatu, ne maily |
| Sdílení kalendáře, termíny, plán, náklady, balení | ano |

## Co nefunguje a proč to zatím nevadí

**Zapomenuté heslo.** Tlačítko je z obrazovky pryč (chybí i obrazovka pro
zadání nového hesla). Řeší se v dashboardu: Authentication → Users. Při počtu
uživatelů v jednotkách je to minuta práce, u dvanácti testerů únosné, u
veřejného vydání ne.

**Potvrzení schránky.** Nikdo neověří, že adresa patří tomu, kdo ji zadal.
Pro uzavřené testování je to jedno. Před veřejným spuštěním ne — kdokoli by si
mohl založit účet na cizí adresu.

**Upozornění a připomínky** (M10) budou chtít push, ne mail, takže je to
neblokuje.

## Kdy se k tomu vrátit

Nejpozději před otevřením closed testu na Play, protože tam už uživatel
zapomenuté heslo nemá kde řešit.

Až na to dojde, nejlevnější cesta není nový účet u další služby, ale **SMTP
Gmailu s heslem aplikace** — `smtp.gmail.com:587`, jméno je tvoje adresa,
heslo je vygenerované *app password* (vyžaduje zapnuté dvoufázové ověření).
Limit 500 zpráv denně je na testování řádově dost a odpadá celé ověřování
odesílatele, se kterým jsme se u Brevo prali.

---

## Až e-mail pojede

**Hlavní cesta je e-mail a heslo.** Registrace jednou, potvrzení schránky,
a od té chvíle stačí heslo — bez doručeného e-mailu, bez deep linku.

Proč to tak dopadlo: odkaz i jednorázový kód potřebují, aby mail dorazil, a
odkaz navíc musí trefit zpátky do té konkrétní instalace aplikace. Heslo
nepotřebuje ani jedno. Když SMTP hodilo 504, přihlášení heslem fungovalo dál.

## Co se s potvrzováním děje

`signUp` posílá **potvrzovací e-mail bez `emailRedirectTo`**, takže odkaz míří
na Site URL — obyčejnou webovou adresu. Je to schválně: ten odkaz nemá co
vracet do aplikace, jeho jediná práce je označit schránku za ověřenou. Dovnitř
se člověk dostane heslem, které už má. Kliknout na něj tedy jde i na počítači.

Tím z přihlášení mizí App Links, `assetlinks.json` i Redirect URLs.

Šablona, která se na tohle používá, je **Confirm signup**, ne *Magic Link* —
to jsou dvě různé šablony a změna jedné se do druhé nepromítne.

## Co ještě chybí

**Zapomenuté heslo.** Odeslat se dá, ale obrazovka pro zadání nového hesla
neexistuje — v routeru není recovery cesta. Tlačítko je proto zatím schválně
pryč; než vznikne, řeší se reset v dashboardu (Authentication → Users).

---

# Dodatek: přihlášení kódem místo odkazem

Cíl: e-mail s **šestimístným kódem** místo magic linku.

Proč to stojí za to i po tom, co bude doména: odkaz vyžaduje App Links,
`assetlinks.json`, správné Redirect URLs — a hlavně **z principu nefunguje,
když si mail otevřeš na počítači a přihlašuješ se na telefonu**, protože PKCE
verifier leží v té konkrétní instalaci aplikace. Kód tuhle celou třídu problémů
odstraňuje.

V aplikaci není co psát. Obrazovka pro kód i `verifyEmailOtp()` existují,
přepíná se to jedním dart-define.

---

## Pořadí

Nedá se přeskládat. Každý krok předpokládá předchozí.

| # | Kde | Co |
|---|-----|-----|
| 0 | git | Commit + push opravy `INTERNET` |
| 1 | Brevo | Účet, ověřený odesílatel, SMTP klíč |
| 2 | Supabase | SMTP nastavení |
| 3 | Supabase | Šablona → `{{ .Token }}` |
| 4 | Aplikace | `EMAIL_OTP_CODE = true` |

---

## 0. Nejdřív síť

Dokud v APK chybí `android.permission.INTERNET`, spadne kód úplně stejně jako
odkaz — je to o vrstvu níž a se SMTP to nesouvisí.

    git add -A
    git commit -m "fix(android): INTERNET do main manifestu"
    git push

Workflow teď po buildu ověřuje, že to oprávnění v APK opravdu je, takže
podruhé to neprojde tiše.

---

## 1. Brevo

**Založit účet** na brevo.com. Free tarif dává 300 e-mailů denně, což je na
testování řádově víc než dost.

**Ověřit odesílací adresu.** Settings → Senders, domains & IPs → *Senders* →
Add a sender. Vlož svoji adresu, Brevo na ni pošle potvrzovací kód.

> Doménu ověřovat nemůžeš — hotmail.com ani gmail.com ti Brevo neautentizuje,
> protože ti nepatří. Bez autentizované domény Brevo tvoji adresu v poli *From*
> nahradí svou vlastní compliant adresou. Pro testování sám sobě je to jedno.
> Než to dostane dvanáct testerů, chce to `planto.app` a DKIM — jinak půlka
> mailů skončí ve spamu.

**Vytvořit SMTP klíč.** Settings → **SMTP & API** → záložka *SMTP*. Na téhle
stránce jsou dvě věci, které budeš potřebovat:

- **Login** — vypadá jako `xxxxxx@smtp-brevo.com`. To je uživatelské jméno.
  Není to adresa tvého účtu a není to `smtp-relay.brevo.com`.
- **SMTP key** — vygeneruj nový. Zobrazí se **jednou**, zkopíruj si ho hned.
  Heslo k účtu jako SMTP heslo nefunguje.

---

## 2. Supabase → SMTP

Authentication → Emails → **SMTP Settings**, přepínač *Enable Custom SMTP*
zapnout.

> **Zkontroluj přepínač projektu v hlavičce.** Aplikace míří na
> `dehgpsnemmemnxbhujai` — ověřeno přímo z binárky APK. Nastavit tohle na
> druhém projektu je nejsnazší způsob, jak strávit hodinu nad něčím, co je
> celou dobu správně.

| Pole | Hodnota |
|------|---------|
| **Sender email address** | ta adresa, kterou jsi ověřil v kroku 1 |
| **Sender name** | `PlanTo` |
| **Host** | `smtp-relay.brevo.com` |
| **Port number** | `587` |
| **Minimum interval per user** | `20` |
| **Username** | Login z Brevo, tvar `xxxxxx@smtp-brevo.com` |
| **Password** | SMTP klíč z kroku 1 |

K dvěma z nich vysvětlení:

**Port 587, ne 465.** Brevo povoluje obojí, ale 587 (STARTTLS) je to, co sami
doporučují a co spolehlivěji projde přes firewally. Ve formuláři je
předvyplněná 465 — přepiš to.

**Interval 20 s, ne 60.** Je to minimální odstup mezi dvěma maily témuž
člověku. Šedesát vteřin je rozumné do produkce, ale při ladění budeš ten kód
posílat opakovaně a minuta čekání po každém pokusu je zbytečné utrpení. Před
vydáním to vrať na 60.

Ještě zkontroluj **Authentication → Rate Limits** — limit na odesílané e-maily
je oddělený od SMTP nastavení a umí tě zastavit dřív než Brevo.

---

## 3. Šablona

Authentication → Emails → **Templates** → *Magic Link*.

Nahraď `{{ .ConfirmationURL }}` za `{{ .Token }}`. Například:

    <h2>Přihlášení do PlanTo</h2>
    <p>Váš kód:</p>
    <p style="font-size:28px;letter-spacing:4px"><b>{{ .Token }}</b></p>
    <p>Platí 60 minut. Když jste o něj nežádali, tenhle e-mail ignorujte.</p>

Editace šablon je na free tarifu odemčená **jen s vlastním SMTP** — nové free
projekty na vestavěném maileru je od 3. června 2026 měnit nemůžou. Proto je
krok 2 podmínkou tohohle. Když editor nejde otevřít, SMTP se neuložilo.

---

## 4. Přepnout aplikaci

Až po kroku 3. Kdyby se to zaplo dřív, přijde e-mail s odkazem a aplikace bude
čekat na kód, který v něm není.

**Lokálně** — `env/dev.json`:

    "EMAIL_OTP_CODE": true

**APK** — Actions → Build APK → Run workflow → zaškrtnout *email_otp_code*.

Tlačítko se přejmenuje na „Poslat kód" a po odeslání se otevře obrazovka se
šestimístným polem, které se odešle samo po šestém znaku.

---

## 5. Test

1. Zadat e-mail → **Poslat kód**
2. Mail dorazí (zkontroluj i spam — bez autentizované domény to hrozí)
3. Opsat kód → přihlášení projde

Když něco spadne, hláška v dev buildu ukáže slova poskytovatele — `errorText()`
je pouští ven schválně. Nejčastější:

| Hláška | Co to je |
|--------|----------|
| `Error sending confirmation email` | špatný SMTP klíč nebo login |
| mail nedorazí a chyba žádná | neověřený odesílatel v Brevo |
| `email rate limit exceeded` | Authentication → Rate Limits, ne Brevo |
| `Failed host lookup` | chybí `INTERNET`, vrať se na krok 0 |
| `Token has expired or is invalid` | starý kód, nebo se mezitím poslal nový |

---

## Co se změní s doménou

Až bude `planto.app`, v Brevu přibude *Domains* → přidat doménu → doplnit DKIM
a Brevo kód do DNS. Pak přestane přepisovat *From*, e-maily budou chodit
z `noreply@planto.app` a doručitelnost se srovná. V Supabase se změní jediné
pole — *Sender email address*.
