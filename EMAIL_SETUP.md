# Přihlášení kódem místo odkazem

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
