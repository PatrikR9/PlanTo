# PlanTo — session log

**Session:** 28–30 July 2026
**Scope:** from a blank folder to a running Android-first app with milestones M0–M4 implemented.
**Companions:** `PlanTo_architecture.md` (v1.1), `PlanTo_costs_and_dependencies.md` (v1.1), `README.md`.

---

## 1. Where the project stands

| | |
|---|---|
| Repo | `github.com/PatrikR9/PlanTo`, branch `main` |
| Backend | Supabase `dehgpsnemmemnxbhujai`, region **eu-central-1** (confirmed) |
| Platform | Android; iOS deferred to V2; Chrome used as a dev target only |
| Code | 54 Dart files (~5,200 lines), 1 Kotlin plugin, 6 SQL migrations (~970 lines incl. tests) |
| Tests | 20 cases across 5 files, all green as of last run |
| `flutter analyze` | clean of errors and warnings; remaining items are mechanical lints |
| Fixed monthly cost | **€0** |

### What works end to end

- Sign in by email (magic link) and as a guest; sign out; guest → full account conversion
- Create a trip, list trips, open a trip, invite by link, redeem a link, join without an account
- Availability engine in Postgres (`group_free_days`, `top_free_days`) with correctness tests
- Design system, theming (light/dark + Material You), routing, error handling, CI

### What is written but unverified

- **The Kotlin calendar plugin.** Never compiled — there is no Flutter SDK in the environment it was written in, and it cannot run on web at all. Two build-configuration errors in it were found and fixed on 30 July (see items 19–20 below); it still needs a real Android device to confirm.
- **The end-to-end calendar sync.** Same reason.

### Not started

M5 (dates & voting UI), M6 (weather), M7 (transport & budget), M8 (Engine planner & packing), M9 (AI + paywall), M10 (chat & notifications), M11 (polish), M12 (release).

---

## 2. Documents produced

**`PlanTo_architecture.md` — v1.0 → v1.1.** All 21 requested sections, plus a risk register and a decisions log. Revised twice: once to rename WeTrip → PlanTo and record the answers to the open questions, once for the Android-first and AI-optional changes.

**`PlanTo_costs_and_dependencies.md` — v1.0 → v1.1.** Every unavoidable payment, every usage-triggered cost, and a dependency register that answers one question per free service: *can I still use this on the day I take my first euro?* Nine services answer no.

---

## 3. Decisions taken this session

| # | Decision | Reason |
|---|---|---|
| 1 | Name **PlanTo**, links on GitHub Pages for now | `planto.app` not yet bought. A Hong Kong fintech already ships a "Planto" app — different market and class, but check ÚPV/EUIPO before filing a trademark |
| 2 | **Android first**, iOS in V2 | Removes Apple's $99/yr, the Mac requirement, EventKit, Sign in with Apple and Codemagic. Year-one fixed cost fell from ~€420 to **~€37**; timeline shortened ~3 weeks |
| 3 | **AI is a paid feature; the free tier uses no AI at all** | "Engine mode" (deterministic solver, weather scoring, cost model, packing rules) is the whole free product. Marginal cost of a free user is €0.00, and worst-case AI spend is capped at ~6 % of AI revenue by a server-side quota |
| 4 | **Czech is the source locale** (`cs.arb`), English second | Nothing user-visible is stored as a finished sentence — DB columns hold l10n keys plus params. Czech past tense agrees with gender and has three plural forms, so sentences must be assembled by ICU on the client. `profiles.gender` exists for exactly this |
| 5 | Supabase (Postgres) as the core; Firebase only for FCM + Crashlytics | The core algorithm is set algebra over time ranges. Postgres multiranges do it in one ~20 ms query; Firestore would push it into Dart on every device |
| 6 | Destinations sourced from **Wikidata (CC0)**, not OpenStreetMap | A curated table extracted from OSM is an ODbL *Derivative Database* and inherits share-alike. The most-missed legal trap in travel apps |
| 7 | Invites as **security-definer RPCs**, not Edge Functions | Everything the function needed to do is database work. No separate deploy, no cold start, validation next to the data. Documented with the condition under which it moves back |
| 8 | Trip creation as **one scrolling form**, not the 3-step wizard in the architecture | Six fields, four with good defaults. A wizard turns one scroll into three screens and two extra taps, against the product's first principle |
| 9 | **Own Kotlin calendar plugin** instead of an off-the-shelf one | Existing plugins hand Dart full event objects including titles. Our projection lists every column the app can read; `TITLE`, `DESCRIPTION`, `EVENT_LOCATION` and attendees are absent. The privacy promise is enforced by the code talking to the content provider, not by Dart discipline |
| 10 | Link sharing via **clipboard**, not `share_plus` | One less dependency that behaves differently on web. Swap during the Android polish pass; link generation is unaffected |

---

## 4. Milestones delivered

### M0 — Foundations
Flutter project, three flavours, strict lints, GitHub Actions CI (analyse, format, test, migration lint, solver tests, **GPL/AGPL dependency rejection**, Supabase keep-alive cron), design tokens, light/dark theme via `ThemeExtension`, 7 components including the signature score ring, GoRouter shell with three tabs, sealed `Failure` hierarchy, Czech-source l10n.

### M1 — Authentication
`AuthRepository` behind a domain interface, guest (anonymous) sessions, email OTP/magic link, Google OAuth (gated off), sign-out, refresh token in EncryptedSharedPreferences via Keystore, and a **database trigger that creates the profile row** — done in SQL rather than the app so a user whose sign-up succeeds but whose profile insert fails cannot exist in `auth` and nowhere else.

### M2 — Trips
`create_trip` RPC (one transaction: insert trip *and* make the creator organiser), `trips_list` view with `security_invoker`, trips list with a **next-action line** on each card ("Čekáme na 2 z 5"), one-screen create form, 20 hard-coded origin cities (no geocoder dependency — public Nominatim forbids interactive lookups).

### M3 — Invites
`create_invite` / `preview_invite` / `redeem_invite` / `revoke_invite`. Only the SHA-256 of the token is stored, so a database leak hands out no working links. `preview_invite` is granted to the `anon` role because the preview must render for someone who has never installed the app — that is the entire growth loop. `redeem_invite` uses `FOR UPDATE` so two taps on a use-limited link cannot both win, and only a genuinely new membership consumes a use.

### M4 — Calendar and availability
Kotlin `CalendarProvider` channel reading `Instances.CONTENT_URI` (recurrence, exceptions and moved occurrences resolved natively — doing that in Dart is a classic DST bug source). On-device processing before anything leaves: clip to the trip window, round outward to 15 minutes, merge overlapping and touching blocks. Eight tests cover it. Explain-first permission sheet, availability heatmap strip, best-days list, immediate delete on disconnect.

---

## 5. Bugs found and fixed

Ordered by how much damage they would have done.

### Security

| # | Bug | Consequence if shipped |
|---|---|---|
| 1 | `revoke update (plan, …) on profiles` — a **column-level REVOKE does not carve a hole out of a table-level grant**, and Supabase grants ALL to `authenticated` by default | **Any user could set their own `plan` to `'pro'`** and unlock every paid feature with one request. Fixed by revoking table-level UPDATE and granting the permitted columns back explicitly |
| 2 | `group_free_days` was `security definer` (it must be — nobody may `SELECT` from `busy_intervals`) but **never checked trip membership** | **Any authenticated user could read any group's schedule** by guessing a trip id. Fixed with an explicit membership guard inside the function; the test asserts a non-member gets zero rows |
| 3 | `trips_list` view without `security_invoker = true` | The view would run as its owner and **return every trip in the database**, bypassing RLS entirely. One-line difference between working and catastrophic |
| 4 | Anonymous → permanent conversion used a normal sign-in | Supabase would mint a **new user id** and silently orphan every trip the guest had joined. Fixed with `updateUser` + `OtpType.emailChange` and `linkIdentity` |

### Breakage

| # | Bug | Symptom |
|---|---|---|
| 5 | `WidgetsFlutterBinding.ensureInitialized()` outside `runZonedGuarded`, `runApp` inside it | "Zone mismatch", blank white page. Found by reading the browser console |
| 6 | `window` used as a column name | **`window` is a reserved keyword in PostgreSQL** — the whole migration failed. Renamed to `date_window`; the rest of the schema was audited against the full reserved list |
| 7 | RLS guardrail raised on PostGIS's own `spatial_ref_sys` | Migration failed. Guardrail now excludes extension-owned tables generally, not by name |
| 8 | Router: `if (signedIn && location == /auth) → /trips` | **A guest is signed in**, so the "Přihlásit se" button bounced straight back and appeared to do nothing |
| 9 | After a successful guest sign-in, nothing navigated away from `/auth` | Sign-in succeeded and looked like it had failed |
| 10 | `array_agg(...) filter (...)` returns `NULL`, not `'{}'` | Null arrays reaching Dart. Wrapped in `coalesce` |
| 11 | `anonKey` deprecated in `supabase_flutter` 2.16 | Renamed to `publishableKey` |
| 12 | `pubspec.yaml` declared `assets/images/` and four Inter fonts that did not exist | Build failure. Directory created; fonts made optional behind `kUseBundledInter` so a fresh clone builds with no downloads |
| 13 | `CardThemeData` vs `CardTheme` differs across Flutter versions | Card styling moved into `PtCard`, making the project resilient to SDK upgrades |
| 19 | The `planto_calendar` plugin pinned **its own AGP 8.1.0 and Kotlin 1.9.22** in a `buildscript` block, while the app uses **AGP 9.0.1 / Kotlin 2.3.20** | Two AGP versions on one build classpath cannot configure. The Android build failed, so the phone kept running an older APK (instant crash) and the emulator had nothing to install. Rewritten in the declarative `plugins {}` form, inheriting versions from the app |
| 20 | The plugin called `ContextCompat` / `ActivityCompat` **without declaring `androidx.core`** | A library module does not get androidx transitively — a straight compile failure. Removed androidx entirely: every one of those calls exists on `Context`/`Activity` from API 23 and minSdk is 24, so the plugin now has **zero dependencies** |

### Honesty and UX

| # | Bug | Fix |
|---|---|---|
| 14 | `canCreate` hid the create button whenever there was no session — including local-only mode, which exists *to review UI* | `capabilities.dart`: everything permitted without a backend; a guest gets an explanation and a way out instead of a missing button |
| 15 | Auth errors shown in a snackbar | Snackbars vanish after four seconds, and a silent failure is indistinguishable from a dead button. Errors now persist on screen, with the provider's own message in debug builds |
| 16 | `email_exists` on guest conversion surfaced as "sign in again" | An infinite loop with no explanation. Now names the problem and offers "sign in to the existing account", stating plainly that guest trips will not come along — Supabase cannot merge identities |
| 17 | `over_email_send_rate_limit` (429) surfaced as "sign in again" | Actively misleading: retrying is exactly what will not work. Now explains the 2-per-hour project-wide cap and points at guest sign-in |
| 18 | The DEBUG ribbon | Removed |

---

## 6. Invite links on GitHub Pages

`planto.app` does not exist yet, so invite links now point at
`https://patrikr9.github.io/PlanTo/i/<token>`, configurable per build via the
`INVITE_BASE` dart-define — once a link is in a group chat it lives forever, so
the value must be swappable without touching code.

`docs/404.html` **is** the invite page. GitHub Pages has no server-side routing
and serves `404.html` for any unknown path, so the page reads the token out of
its own URL. It then calls `preview_invite` directly with the anon key and
renders the real trip details, which means **the growth loop works today with
the app not installed at all** — exactly what granting that function to the
`anon` role was for.

**`android:autoVerify` is deliberately off.** App Links verification requires
`/.well-known/assetlinks.json` at the *domain root*, and a GitHub project page
can only serve files under `/PlanTo/`. Serving it would need a repo named
`patrikr9.github.io`, or the real domain. Without `autoVerify` the link still
opens the app — through the "open with" chooser rather than directly. Turn it
on together with `planto.app`.

**To publish:** GitHub → Settings → Pages → Source `main`, folder `/docs`.

---

## 7. Blockers

| # | Blocker | Effect | Way out |
|---|---|---|---|
| 1 | Supabase built-in mailer: **2 emails/hour project-wide**, and since 3 June 2026 free-tier projects on it **cannot edit auth templates** | Email sign-in is barely testable; the mail is a link, not a code | Brevo or Resend SMTP. Brevo will verify a single personal address without a domain — ~10 minutes, free. Cap rises to 30/hour and template editing unlocks; then set `EMAIL_OTP_CODE: true` and the code screen (already built) takes over |
| 2 | No `planto.app` | Blocks App Links verification, DKIM-signed mail, and the Android Google OAuth client — three things at once | Buy it (~350 Kč). Needed for M12 regardless |
| 3 | Google sign-in has no OAuth client | Button hidden behind `GOOGLE_SIGN_IN: false` | Google Cloud → OAuth client → paste into Supabase → flip the flag |
| 4 | Play requires **12 testers running a closed test for 14 continuous days** before an individual account gets production access | The likeliest cause of a late launch — the store rule, not the code | Recruit now; open the closed track around M10 |
| 5 | Kotlin plugin never compiled | M4 unverified | Run on a real Android device |
| 6 | No merge for guest → existing account | A guest who signs into an existing address loses trips they joined | Future RPC that reassigns `trip_participants.user_id` under `service_role`. Irreversible on other people's data, so it deserves its own milestone and real tests |

---

## 8. Next steps, in order

1. `flutter pub get` (the `planto_calendar` path dependency is new), then `flutter test`
2. `supabase db push` — six migrations
3. Enable GitHub Pages (`main` / `/docs`) and test an invite link in a browser with no app installed
4. **Run on a real Android device** and verify the calendar sync — this is the milestone that can genuinely fail, and it is better to learn that now than at week 14
5. Set up Brevo SMTP to unblock email testing
6. Buy `planto.app`
7. Start recruiting the 12 Play testers
8. Then **M5 — dates and voting**, which is where the product's core promise finally becomes visible

---

## 9. Conventions established

- **Nothing user-visible is stored as a finished sentence.** DB columns hold l10n keys plus params (`title_key`, `reason_key`, `system_key`). ICU assembles sentences on the client.
- **No feature code hard-codes a colour, size, radius or duration.** Use `Sp`, `Radii`, `Motion`, `context.planto`.
- **No `catch (e)` in a widget.** Exceptions map to `Failure` once, at the repository boundary; the UI switches on the sealed type.
- **Layering:** `presentation` may import `domain` and `core`, never `data`. A `usecase` class exists only when it orchestrates two or more repositories.
- **The client never talks to a third party directly.** That is what makes "no API keys in the app" structurally true rather than aspirational.
- **The free tier calls no AI.** If a path a free user can reach needs an LLM, stop.
- **Every repository has an `Unconfigured…` variant** so the app runs, and screens can be reviewed, with no backend at all.

---

---
---

# Session 2 — 30 July – 3 August 2026

M5 through M7, a web build, and eight bugs. Written for somebody picking this
up cold: what exists now, what each decision cost, and what is still open.

## 10. What was built

| Milestone | State |
|---|---|
| **M5** dates & voting | Done. Three-state voting, live tallies, organiser lock |
| **Granularity** | Done. A trip plans in whole days *or* in time slots |
| **M6** weather | Done. Deterministic scoring, in the ranking, not just on the card |
| **Calendar by link** | Done. iCal subscription, works in a browser |
| **M7** transport | Half. Distances, durations and cost estimates. No timetable |
| **Web build** | Deployed to GitHub Pages so an invite works with no app |

Five new migrations, three Edge Functions, three SQL test files, one new
Flutter feature package (`transport`), one deleted screen.

## 11. The model change that made the rest cheap

A candidate is now a `[starts_at, ends_at)` range in **both** granularities. A
day-mode candidate is simply one whose range happens to be whole days.

That is the whole trick. One vote table, one lock, one ranking formula, one
card, one screen — instead of a day feature and an hours feature that would
have drifted apart within a month. Everything after it (weather, the Dates
tab, locking) was written once.

`trips` gained `granularity`, `slot_minutes`, `slot_step_minutes`,
`day_start`, `day_end`, `locked_range`. `date_votes.day date` became
`slot_start timestamptz`.

## 12. Decisions worth keeping

**Slot merging.** Consecutive slots with an identical free set are merged into
one candidate (gaps and islands over `lag()`). Without it a 14-hour day at a
15-minute step produces 52 near-identical cards. With it the group sees
"Pá 11. 9., 12:00–13:30, volno až do 17:00" once.

**Multi-day feasibility.** A block is only proposed if *every* day of it works
for the person. Evaluating the first day alone proposes a Saturday for a
three-day trip when two people work on the Monday.

**Unknown is not bad.** Open-Meteo stops at 16 days; people plan further. If
the missing weather terms were simply dropped, every unknown date would sink
below every sunny one and the screen would read "November is bad" when the
truth is "we do not know yet". `_candidate_score` renormalises the applicable
weights to sum to 1. `_weather_score` returns `null` rather than 100 for the
same reason — with no data every penalty is zero.

**Time order beats score order on screen.** The server still ranks; the list is
chronological with a "Nejlepší" badge. A list that jumps 12 Sep, 3 Nov, 19 Sep
is sorted correctly and scans as noise. The score was never the thing being
compared, the days were.

**No invented departures.** The transport numbers are geometry and a fare
model, labelled *odhad*, with a link into IDOS. "Odjezd 7:14" that is not a
real train is the one number on the screen somebody would act on.

**iCal instead of OAuth.** Google's `calendar.readonly` is a sensitive scope:
verified domain, privacy policy, Google review — and refresh tokens in our
database, which is the exact opposite of why the Android path reads on-device.
Every calendar already publishes a secret iCal URL. No token custody, and the
user can revoke it themselves without telling us.

**One tap to share availability.** The explanation *is* the screen and the
button under it goes straight to the permission prompt. `ConnectCalendarSheet`
was deleted; the explaining it did was worth keeping, the extra tap was not.

## 13. Bugs, and what each one taught

### Postgres

1. **`CREATE OR REPLACE FUNCTION` cannot change a return type**, and for
   `RETURNS TABLE` the output columns *are* the return type. Needs an explicit
   `DROP FUNCTION` first — and the `GRANT` reissued, because the drop takes it
   too. `supabase db push` reports this as "failed to execute statement" and
   prints 200 lines of solver, so it looks like a syntax error.
2. **A parameter with a DEFAULT creates an ambiguous overload**, not a
   replacement. `_candidate_score` went from four args to six; every old call
   site then matched two functions. Drop the old signature in the same
   migration.
3. **`array_agg` over an array column builds a 2-D array**, so `array_agg(x)[1]`
   silently returns NULL. Use `min(anyarray)` when the values in a group are
   known to be identical.

### Dart

4. **A missing trailing comma** after a widget in a collection literal. Caused
   by replacing an `else` branch — the comma belonged to the removed element.
5. **`_instant` declared twice**, once each direction. Dart has no
   overloading; the second declaration is an error, not a sibling.

### The expensive ones — all the same shape

6. **The magic link went to the Site URL.** `emailRedirectTo: kIsWeb ? null :
   …` with a comment saying "on web Supabase returns to the current origin".
   It does not: `null` means the project's Site URL, one fixed value that
   cannot be both localhost and the Pages URL.
7. **The Edge Function swallowed its own reason.** `functions.invoke` *throws*
   on 4xx; the repositories checked a returned error field that never existed.
   Every specific message the function wrote — "Kalendář odpověděl 404",
   "ICAL_SECRET is not set" — arrived as "Něco se pokazilo".
8. **The APK had no config and blamed a file.** `String.fromEnvironment` is
   resolved at *compile* time, so `flutter build apk` without
   `--dart-define-from-file` bakes empty strings in permanently. The banner
   said "env/dev.json chybí"; the file was right there, the flag was missing.
9. **"Přihlaste se prosím znovu" hid a dashboard switch.** Every
   `AuthException` collapses into that one sentence — including "Anonymous
   sign-ins are disabled", which is off by default on a new project and which
   retrying cannot fix.

**Four bugs, one lesson.** None of 6–9 was a logic error. Each cost an exchange
because the app described the problem wrongly, and each fix was to make it
describe the problem correctly. That is now a rule, not a habit:

> No error surface constructs its own message. Everything goes through
> `errorText()`, which shows the provider's own words in any non-production
> build and the friendly sentence only in production. Gated on the **flavour**,
> not on `kDebugMode` — the build being carried around on a phone is a release
> APK built from `env/dev.json`, and that is exactly when this bites.

`tool/build_apk.ps1` exists for the same reason: a footgun with no upside
belongs in a script, not in somebody's memory.

## 14. Still open

| # | Item | Note |
|---|---|---|
| 1 | **Android calendar attach fails** | Reported, not diagnosed. Plugin looks structurally fine — manifest, channel registration and pubspec all correct. Needs `run_log.txt` from a real device |
| 2 | Anonymous + email sign-in | Almost certainly the provider switches in the dashboard. The app will now quote the real error |
| 3 | Supabase dashboard config | Anonymous sign-ins ON, Email ON, Site URL and Redirect URLs set to the Pages URL and `localhost:50350` |
| 4 | Repo secrets + Pages source | `SUPABASE_URL`, `SUPABASE_ANON_KEY`; Pages → Source → GitHub Actions |
| 5 | `ICAL_SECRET` | `supabase secrets set ICAL_SECRET="…"` or the iCal path cannot encrypt |
| 6 | ~~Hard-coded ref in `docs/404.html`~~ | **Closed 4 Aug.** Placeholders substituted by `pages.yml` from the same secrets the Flutter build uses; a `grep` guard fails the step if anybody inlines them again |
| 7 | ~~Open-Meteo variable names~~ | **Closed 4 Aug.** Real forecasts render on the Dates tab — `64/100 · přeháňky · 37 °C · 23 % déšť`. The names are right |
| 8 | Dates tab converts to **device** time, not trip time | `date_repository` calls `.toLocal()` on `starts_at`. Correct in Czechia on a Czech phone, wrong for anyone whose device zone differs from the trip's — and the project already ruled the other way for manual blocks. See §14d |

Carried over from session 1 and unchanged: Brevo SMTP, `planto.app`, the Google
OAuth client, and 12 Play testers for 14 continuous days.

## 14b. Tidy-up pass, 4 August

The session-2 work above was written but never committed, so the first job was
to get it into history before anything else touched it. Three commits: the
cleanup, the feature work, the Pages fix. Nothing has been run yet — §17 still
applies in full.

Two things were wrong on the way in and are fixed:

- `deno test --allow-none` in the new CI job. There is no such flag; Deno
  grants nothing by default, so the flag was both invalid and unnecessary. The
  job would have failed on its first run, which is a cheap failure but a
  confusing one — an unknown argument reads like a Deno version problem.
- **The weather and the transport estimate disagreed about where the trip was
  going.** M7 added `trips.destination_point` for free-text destinations, but
  `_trip_weather_point` still read only `destinations.point` via
  `destination_id`. A trip with a destination picked from `kDestinations`
  would have measured the distance to Špindlerův Mlýn and scored the weather
  in Prague — and both screens would have looked entirely correct. Fixed in
  the transport migration, since that is the migration that created the second
  destination. `set_trip_destination` now also clears `destination_id`: a trip
  holding both kinds of destination has two answers to "where is this going"
  and the schema does not say which one wins.

Both were caught by reading, not by running. Neither survives contact with a
test suite, which is the argument for §17 rather than against it.

## 14c. First run on a device, 4 August

The app went onto an emulator and the calendar flow failed with
`permission denied for table busy_intervals` — surfaced verbatim, in the UI, by
the `errorText()` change from this session. Under the old code it would have
read "Přihlaste se prosím znovu", which is advice that cannot work.

It was not an RLS bug. `SELECT` on `busy_intervals` is revoked from every role
on purpose (§rls), so the raw rows are unreachable and group availability is
only ever exposed as counts through `group_free_days()`. What nobody noticed is
that this makes the table unwritable from the client too: **Postgres requires
`SELECT` on every column a `DELETE` reads in its `WHERE`**, and every upload
begins by deleting the user's previous blocks. The privacy guarantee and the
write path were in direct conflict, and the write path lost.

The manual editor never hit this because it already went through
`set_manual_busy()`. The device-calendar path was still on PostgREST — it was
written first, before that rule existed, and nothing dragged it forward.

Fixed by finishing the job: `set_device_busy()` and `clear_my_busy()`, both
`security definer`, both membership-checked, both clipping to the trip window.
`markShared()` is gone — the flag is now set in the same transaction as the
rows, so it can no longer disagree with them and leave a group waiting on
somebody who is already done.

The interesting part is why the existing tests missed it. They run as
`postgres`, whose privileges nobody checks, so a grant bug is invisible to all
of them. `supabase/tests/busy_write_test.sql` switches to `authenticated` and
asserts both halves at once: that the table cannot be read, and that the upload
still works.

Also fixed here: the "page not deployed" message in `docs/404.html` pointed
people at `planto.app`, a domain that has not been bought. An error message
that sends somebody to a non-existent address is worse than no message.

## 14d. What the first real run proved, and the one thing it exposed

After `set_device_busy` landed, the whole chain ran against the live backend
for the first time: sign in, create a trip, share availability, and a Dates tab
with ranked candidates, live vote controls, a lock button, and **real weather**
— `64/100 · přeháňky · 37 °C · 23 % déšť`. M5 and M6 are verified end to end.
The Open-Meteo variable names, open since session 2 because nobody could check
them from the writing side, are correct.

The score ring reading 100 next to a weather line of 64 is not a bug: the ring
shows availability, the composite score does the ranking, and keeping them
apart is deliberate — a blended number would hide which half was which.

One real finding, and it is latent rather than urgent. The emulator runs on
UTC, so a trip window starting 5 August in Prague (`4 Aug 22:00Z`) rendered as
**"Úterý 4. 8."** — a day before the trip can even begin. `date_repository`
calls `.toLocal()`, which is right on a Czech phone in Czechia and wrong for
everybody else: someone in Vienna sees one date, someone in London another, for
the same trip. The project already rejected exactly this for manual blocks —
"the RPC interprets each date and wall-clock time in the *trip's* timezone,
which is the only correct reading and the only one a travelling user gets
right" — and the Dates tab quietly does the opposite.

Fixing it properly means `trip_candidates` returning wall-clock parts in the
trip's zone the way `my_busy_blocks` already does, which is a DROP-and-recreate
(trap 8) plus client changes. It is not blocking anything today and it is not
a five-minute patch, so it is item 8 rather than a rushed commit.

To make the emulator stop lying in the meantime:

    adb shell setprop persist.sys.timezone Europe/Prague

## 14e. M7 finished — the Costs tab

The blank Costs tab was not a bug, it was `Center(Text('Náklady — brzy'))`: the
transport migration calls itself "M7, first half" and the second half was never
written. It is written now.

`estimate_trip_cost()` returns a breakdown rather than a number, every line per
person, every line a range. Transport comes from `transport_options()` — the
cheapest option by midpoint, not the sum, because summing both modes charges
for the journey twice and mixing the min of one with the max of the other
produces a range that describes no actual trip. Food is a national daily
average times the duration. The buffer is a percentage of the rest.

Two decisions worth keeping:

- **No destination, no rows at all** — not even food and buffer. Transport is
  usually the largest item, so a total without it is not an incomplete
  estimate, it is a different number that looks like one. Same silence as the
  Plan tab, at the same moment.
- **Accommodation returns a row with no numbers.** It is V1 scope, and on a
  three-day trip it is the biggest line in the budget. Omitting it silently
  would make the total a lie; a zero would claim the bed is free. `unknown` is
  the only honest third state, and the total then reads "od 780 Kč" rather than
  "≈ 780 Kč" — one word, and it is the whole difference between an estimate and
  a floor.

`budget_per_person` finally does something: the total says whether it fits, and
says "horní odhad je nad rozpočtem" rather than "překročeno", because the top of
a range is the pessimistic end and has not happened yet.

## 14f. M8 — the Packing tab

Rules, not a model. "Prší v sobotu odpoledne, vezmi pláštěnku" has to come out
the same every time, be testable and cost nothing, which is the definition of a
rule rather than a prompt. AI adds what the rules do not know, and that is the
paid layer — nothing a free user can reach touches an LLM.

`packing_rules` holds 45 seeded rules whose predicates are all nullable, and
null means "don't care". A rule fires when **all** its filled predicates match:
a conjunction, not a score. A score would mean a marginal rule appears some
days and not others, and an unpredictable packing list stops being checked at
all.

The decision that matters is the same one `_weather_score` already made:
**missing forecast must never read as good weather.** With no cached forecast,
every weather predicate is NULL and therefore false, so those rules simply do
not fire. Had the absent row been read as "0 mm, 0 gusts, 0 snow", the list
would confidently tell a group planning six weeks out that they need nothing
extra — the one piece of advice this screen must never give by accident.

Every row carries its cause, phrased as a cause and not an instruction. "Prší
odpoledne" is something you can weigh; "vezmi si pláštěnku" just repeats the
item above it. A list with no reasons cannot be argued with, so people either
carry everything forever or stop reading it.

Ticking is optimistic and per user. Optimistic because the list is used
standing in a hallway with one hand full — a round trip per checkbox is
unusable — and per user because "who is carrying the first aid kit" is group
task-splitting, which is V2. Half-sharing it would mean one person ticking an
item hides it from everybody else.

`packing_test.sql` asserts the no-forecast case first, then that hiking rules
do not reach a lake trip, that a car trip gets no ticket-app rule, and that
Anna ticking the water does not tick it for Bohuš.

## 14g. Notes on the two test files

`costs_test.sql` runs as `authenticated` — the lesson from `busy_intervals` is
that a grant bug is invisible to any test running as `postgres`. It asserts that
transport appears exactly once, that food scales with duration, that the
multi-day trip admits the missing bed, that no range has min > max, and that a
non-member sees nothing.

## 15. Licence debts, restated

Three things in this session are free **only** while PlanTo takes no money:

- **Open-Meteo** free API — non-commercial. Self-host before the first euro.
  One line changes; the URL is already `Deno.env.get("OPEN_METEO_URL")`.
- **Transitous / MOTIS** — community service, no commercial licence. This is
  why M7 has no timetable, and self-hosting it is what finishes M7.
- **Destination coordinates** must come from **Wikidata (CC0)**, never
  OpenStreetMap — ODbL would make the table a Derivative Database with
  share-alike. `kDestinations` is twenty entries typed by hand, which is a
  derivative of nothing, and it goes away when the table is seeded.

## 16. Which Supabase project

`dehgpsnemmemnxbhujai`. It agrees in three independent places: `env/dev.json`,
`supabase/.temp/project-ref`, and the hard-coded constant in `docs/404.html`.
The second project is empty — no schema, no functions.

## 17. Nothing here has been run

There is no Flutter SDK, no database and no Deno on the assistant side. Every
line was written unverified and is only as good as the next run:

    dart fix --apply && dart format lib test
    flutter analyze --fatal-infos
    flutter test
    deno test supabase/functions/_shared/
    supabase db push
    supabase functions deploy weather
    supabase functions deploy ical-sync
    psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/dates_test.sql
    psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/weather_test.sql
    psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/transport_test.sql
