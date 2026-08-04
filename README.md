# PlanTo

Group trip planning that finds the date for you.
**Android · Czech-first · Flutter + Supabase.**

This repository is **milestone M0: Foundations** from `PlanTo_architecture.md`.
It compiles, runs, and contains the real database schema and the real
availability solver. The screens are deliberately thin — they exist to prove
the shell, the theme and the routing work end to end.

---

## What is actually built

| Area | State |
|---|---|
| Design system | Tokens, light + dark theme, `PlanToTheme` extension, 6 components incl. the score ring |
| Routing | GoRouter, 3-tab shell, trip detail outside the shell, `/i/:token` outside auth guards, rail layout at ≥840dp |
| Error handling | Sealed `Failure` hierarchy + repository-boundary mapper |
| Auth plumbing | Supabase client, session/auth-state providers, entitlement from the JWT `plan` claim |
| **Database** | **Full schema, complete RLS, the availability solver, and its correctness tests** |
| CI | Analyse, format, test, migration lint, solver tests, GPL/AGPL dependency check, Supabase keep-alive |
| l10n | Czech as the *source* locale, with the ICU gender/plural patterns Czech requires |
| Screens | Placeholders — M1 onward |

The database layer is the most finished part on purpose: it is what the rest
of the app is shaped by, and it is the part that is expensive to change later.

---

## Your side: setup, in order

### 1. Prerequisites (~20 min)

```bash
# Flutter 3.27+ — https://docs.flutter.dev/get-started/install/windows
flutter --version
flutter doctor          # resolve everything except the iOS/Xcode rows

# Supabase CLI — https://supabase.com/docs/guides/cli
npm install -g supabase
supabase --version
```

Android Studio (for the SDK and an emulator) plus a **real Android phone** —
calendar permissions behave differently on hardware, and M4 depends on that.

### 2. Scaffold the platform folders (2 min)

This repo has no `android/` or `web/` folder — those files are generated, not
authored.

```bash
cd planto
flutter create . --project-name planto --org app.planto --platforms=android,web
flutter pub get
flutter gen-l10n
```

`flutter create` will not overwrite anything here; it only fills in what's missing.

> **Why web is enabled.** The product ships Android-only (web is V2). Chrome is
> included purely as a *development* target: hot reload is faster and you don't
> need an emulator running to review a screen. Do not build features that only
> work on web, and always verify on a real Android device before calling
> anything done — `flutter_secure_storage` and the calendar channel behave
> differently there.

### 2b. Run it right now, with no backend

The app deliberately starts without Supabase configured, in a local-only mode
with a red stripe at the bottom of the screen:

```bash
flutter run -d chrome
```

This exists so UI work is never blocked on backend setup. Sign-in is skipped
and you land straight on the trips shell.

### 3. Create the Supabase projects (~10 min)

Two projects on the free tier — the free plan allows exactly two:

- `planto-staging`
- `planto-prod`

**Choose region `eu-central-1` (Frankfurt).** This is a GDPR commitment, not a
latency preference, and it cannot be changed after creation.

Then link and push the schema:

```bash
supabase link --project-ref YOUR_STAGING_REF
supabase db push
```

Verify the solver works:

```bash
psql "YOUR_DB_CONNECTION_STRING" -v ON_ERROR_STOP=1 \
  -f supabase/tests/availability_test.sql
# expect: NOTICE availability solver: OK / NOTICE membership guard: OK
```

### 4. Wire the credentials (2 min)

```bash
cp env/dev.json.example env/dev.json
```

Fill in the project URL and the **anon** key from Supabase → Settings → API.

> The anon key is public by design — it ships in the APK and that is fine,
> because RLS is what protects the data. The **service_role** key must never
> appear in this repo, in `env/`, or in any Dart file. It belongs only in Edge
> Function secrets.

`env/dev.json` is gitignored. Keep it that way.

### 5. Run it

```bash
flutter run -d chrome --dart-define-from-file=env/dev.json   # fast iteration
flutter run --dart-define-from-file=env/dev.json             # real device
flutter test
```

The red stripe disappears once the backend is wired. You should get the
sign-in screen; the trip detail route already renders the score ring, so try
`/trips/demo?tab=overview`.

### 6. Fonts — optional, the build is green without them

Download [Inter](https://rsms.me/inter/) and drop these four files into
`assets/fonts/`:

```
Inter-Regular.ttf  Inter-Medium.ttf  Inter-SemiBold.ttf  Inter-Bold.ttf
```

Then uncomment the `fonts:` block in `pubspec.yaml` and set
`kUseBundledInter = true` in
`lib/core/design_system/tokens/typography.dart`.

Until you do, the app uses the platform default (Roboto), which looks fine.
Inter is SIL OFL 1.1 — free commercially, with complete Czech diacritics.
Bundling rather than fetching keeps first paint offline-safe. Add the licence
text to the in-app licences screen in M11.

---

## Your side: things to start *now*, in parallel with development

These have lead times and will otherwise become the critical path.

| # | Task | Why now | Deadline |
|---|---|---|---|
| 1 | **Recruit 12+ testers** | Google requires an individual developer account to run a **closed test with 12 testers for 14 continuous days** before production access. This is the likeliest cause of a late launch — not the code | Start now; track open by M10 |
| 2 | **Buy `planto.app`** | Goes into the Android App Links config, the invite landing page and the Supabase auth redirect allowlist. Painful to change once links are shared | Before M3 |
| 3 | **Google Play Developer account** ($25) | Identity verification takes days, sometimes weeks | Before M10 |
| 4 | **Reserve the Play listing name** | "Planto" is used by a Hong Kong fintech. Different market, but reserve early | With #3 |
| 5 | **Set up transactional email** (Resend or Brevo, free) | Supabase's built-in mailer is development-only — email OTP login will not work in production without it | Before M1 finishes |
| 6 | **Enable Gemini billing** | The free tier trains on your data, which contradicts the privacy positioning | Before any public build |

---

## Conventions worth knowing before you write code

**Nothing user-visible is stored as a finished sentence.** Database columns hold
l10n keys plus parameters (`title_key`, `reason_key`, `system_key`), never
Czech text. Czech past tense agrees with gender and it has three plural forms,
so sentences must be assembled by ICU on the client. `profiles.gender` exists
for exactly this. Retrofitting it later is brutal.

**No feature code hard-codes a colour, size, radius or duration.** Use `Sp`,
`Radii`, `Motion` and `context.planto`.

**No `catch (e)` in a widget.** Exceptions are mapped to `Failure` at the
repository boundary and the UI switches on the sealed type.

**Layering:** `presentation` may import `domain` and `core`, never `data`.
A `usecase` class is only created when it orchestrates two or more
repositories — one that forwards a single call gets deleted.

**Free tier calls no AI.** Engine mode is the default renderer. If you find
yourself adding an LLM call to a path a free user can reach, stop.

---

## What comes next

**M1 — Auth & profiles.** Google Sign-In, email OTP, anonymous sessions,
profile creation, router guards.

Then **M4 (calendar) before M8 (planner)**, because calendar access is the
only milestone that can genuinely fail. Better to learn that in week 6 than
week 14.


---

## Email sign-in: current state and how to finish it

Since **3 June 2026** a free-tier Supabase project using the built-in mailer
**cannot edit its auth email templates**, and that mailer is capped at
**2 emails/hour** and refuses to send to anyone outside your project team.

So the login mail arrives as a **magic link, not a 6-digit code**. The app
handles both: `emailRedirectTo` is set, so tapping the link completes the
sign-in (on web supabase_flutter reads the session out of the URL; on Android
the `app.planto://login-callback/` deep link does it).

### Right now, to develop without any of this

Use **Pokračovat jako host** on the sign-in screen. Anonymous sign-in needs no
email, no SMTP and no domain — and it is the same code path a real invitee
uses when they open a trip link, so it is worth exercising anyway.

For magic links on web, pin the port so the redirect URL stays stable:

```bash
flutter run -d web-server --web-port=50350 --dart-define-from-file=env/dev.json
```

then open `http://localhost:50350` in your normal Chrome and add that URL under
**Authentication → URL Configuration → Redirect URLs**.

> **Use `-d web-server`, not `-d chrome`.** `-d chrome` launches a throwaway
> Chrome profile with an empty storage area, so the session is wiped on every
> restart and you land back on the sign-in screen every time. `web-server`
> serves the app and lets you open it in your own browser, where the session
> survives.

### Running analyze on PowerShell

```powershell
flutter analyze 2>&1 | Tee-Object -FilePath Analyze_logs.txt
```

`flutter analyze > file 2>&1` also works, but PowerShell wraps the tool's
stderr in a `NativeCommandError` and prints a red block that looks like the
command failed when it did not. `Tee-Object` shows the output and writes the
file at the same time.

Most findings are mechanical. Fix them with:

```powershell
dart fix --apply
```

### Feature flags in `env/dev.json`

| Flag | Default | Turn on when |
|---|---|---|
| `GOOGLE_SIGN_IN` | `false` | An OAuth client exists in Google Cloud **and** the Google provider is enabled in Supabase. Until then the button is hidden — a dead sign-in button costs more trust than a missing one |
| `EMAIL_OTP_CODE` | `false` | Custom SMTP is configured and the Magic Link template uses `{{ .Token }}`. Until then the app says "Poslat odkaz" and shows a check-your-inbox panel instead of a code field |

### Enabling Google sign-in

1. Google Cloud Console → **APIs & Services → Credentials → Create OAuth client ID → Web application**
2. Authorised redirect URI: `https://YOUR-PROJECT-REF.supabase.co/auth/v1/callback`
3. Supabase → **Authentication → Sign In / Providers → Google** → paste the client ID and secret
4. Set `"GOOGLE_SIGN_IN": true` in `env/dev.json` and restart

For Android you will additionally need an **Android** OAuth client with your
signing certificate's SHA-1, which only exists once you have a keystore. That
lands with the release build in M12.

### To get real 6-digit codes (do this when the domain lands)

1. Buy `planto.app` — needed for App Links in M3 anyway.
2. Create a free **Brevo** (300 emails/day) or **Resend** (3,000/month)
   account and verify the domain with the DNS records they give you.
   *Without a domain* Brevo will still relay from a single verified personal
   address, which is enough for testing but has poor deliverability, because
   nothing can DKIM-sign mail from a hotmail.com address.
3. Supabase → **Authentication → Emails → SMTP Settings** → paste the host,
   port, user and key. The hourly cap rises to 30 and template editing unlocks.
4. Edit the **Magic Link** template: replace `{{ .ConfirmationURL }}` with
   `{{ .Token }}`.

No application code changes at any point — the OTP screen is already built and
both paths work simultaneously.


## Building an APK for a phone

Use the script, not `flutter build apk`:

```powershell
.\tool\build_apk.ps1
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

`SUPABASE_URL` and `SUPABASE_ANON_KEY` arrive through `String.fromEnvironment`,
which is resolved at **compile** time. A plain `flutter build apk` bakes empty
strings into the binary permanently: the app installs, opens, and runs in
local-only mode with the red stripe, and no amount of reinstalling changes it.
