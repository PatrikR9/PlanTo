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

## 10. Session 2 — 30 July 2026: invite links live, M5 built

### What was actually wrong with the invite link

Nothing in the code. `docs/` had never been committed — the repository had a
single commit — and GitHub Pages was not enabled, so
`https://patrikr9.github.io/PlanTo/i/<token>` returned GitHub's own 404 rather
than `docs/404.html`. Both fixed; the invite page now loads and
`preview_invite` answers with the anon key from a browser with no app
installed. The growth loop works.

### Migration `20260730120000_m5_dates.sql`

| Object | Why |
|---|---|
| `busy_intervals.source_kind` | `calendar` vs `manual`, so the grid can prefill without presenting calendar-derived intervals as something the user typed. Mutually exclusive per (trip, user): both writers replace the whole set, because merging "calendar says free, person says busy" has no correct answer |
| `set_manual_busy_days(uuid, date[])` | Days in, full local-midnight ranges out. **The timezone conversion is server-side on purpose**: the client has no tz database (a dependency plus ~900 kB), Postgres has one, and `trips.timezone` is authoritative. Doing it on the device is also wrong for anyone travelling. An empty array is a real answer and still sets `calendar_shared` |
| `my_manual_busy_days(uuid)` | `SELECT` on `busy_intervals` is revoked from every role, including for your own rows. Reading back what you ticked therefore needs a function |
| `date_votes` + `cast_date_vote` | Three states. "Maybe" is the honest answer to most dates and a poll that forces yes/no collects a number nobody believes. `p_vote null` withdraws |
| `date_candidates(uuid, int)` | Ranked days **with** tallies and the caller's own vote, in one round trip. Supersedes `top_free_days`, which is dropped — its quorum filter showed an empty screen to exactly the groups that most needed to see why their options were bad. One ranking formula, one place |
| `lock_trip_date` / `unlock_trip_date` | Organiser-only, re-checked server-side. Voting informs the decision, it does not make it: a poll that auto-wins on a plurality picks whatever the two fastest repliers said |
| `trips_list` + `locked_start`, `locked_end`, `my_role` | `locked_date` is a `daterange`; PostgREST returns the literal `[2026-09-12,2026-09-14)` and parsing that in Dart is a bug waiting to happen. `my_role` replaces `createdBy == myId`, which is the wrong check the moment an organiser is handed over |

`locked_date` is **half-open**: the last day of the trip is `locked_end - 1`.
`Trip.lockedEnd` is named for that and `trip_test.dart` asserts it.

### Flutter

- `features/dates/` — new feature. `DateCandidate`, `DateRepository`,
  `DatesController`, `DateCandidateCard`, `DatesTab`. The Dates tab replaces
  the read-only list: ranked cards with a vote control, live tallies, a locked
  banner and an organiser-only lock/unlock.
- `ManualAvailabilityScreen` — screen 21, on route
  `/trips/:tripId/availability`. A route rather than a modal because the
  "somebody hasn't shared availability" notification has to deep-link straight
  into it.
- `ConnectCalendarSheet` — "Zadám ručně" used to just close the sheet, which
  read as the app ignoring the answer. It now opens the grid. The manual path
  is also offered on the Overview tab without refusing a permission first.

**Why the manual grid matters more than it looks:** it removes the single
point of failure in an unproven Kotlin plugin. The whole availability → dates →
vote → lock flow can now be exercised end to end on web, with no calendar
permission and no device.

The ring on a date card shows **availability**, not the composite score. The
score decides the order; availability is the one number on the card a person
can check against what they already know about the group.

### Two design choices worth remembering

- The Dates tab shows the "nothing to compute yet" state when
  `calendarSharedCount == 0`, not when the candidate list is empty. The solver
  treats an unknown schedule as free, so with nobody answered every day would
  read "everyone free" — true to the data and completely misleading as a
  proposal.
- Voting is *not* blocked while a date is locked. That is UI state, not
  authorisation, and blocking it server-side would add a failure path for a
  case the UI already prevents.

### Still unverified

Everything in this section was written without a Flutter SDK on the assistant
side. Nothing here has been compiled or run. Before pushing:
`dart format lib test`, `flutter analyze --fatal-infos`, `flutter test`,
`supabase db push`, then `psql -f supabase/tests/dates_test.sql`.

---

## 11. Session 3 — granularity: days or hours

### The model change

A candidate is now a `[starts_at, ends_at)` range in both modes. A day-mode
candidate is simply one whose range happens to be whole days. That is the
whole trick: one vote table, one lock, one ranking formula, one card, one
screen — instead of a second feature bolted alongside the first.

| Column | |
|---|---|
| `trips.granularity` | `day` \| `time` |
| `trips.slot_minutes` | how long the activity is; null in day mode |
| `trips.slot_step_minutes` | 15 / 30 / 45 / 60 — how far apart proposed starts are |
| `trips.day_start`, `day_end` | the usable part of a day, per trip |
| `trips.locked_range` | `tstzrange`, replaces `locked_date daterange` |
| `date_votes.slot_start` | `timestamptz`, replaces `day date` |

`date_votes` was dropped and rebuilt rather than migrated: one day old, no
real rows, and a backfill would add a code path that never runs again.

### The solver

`trip_candidates(uuid, int)` replaces `date_candidates`. plpgsql with an `IF`
rather than one statement with a `UNION`, so the planner never prepares the
slot branch for a day-mode trip.

**Day branch.** A multi-day trip is feasible only if *every* day of the block
works for the person. Evaluating just the first day proposes a Saturday for a
three-day trip when two people work on the Monday — the bug the test now
guards.

**Slot branch.** Slots are generated on the step grid, then consecutive slots
with an *identical free set* are merged into one candidate (gaps and islands
over `lag()`). Without that, a 14-hour day at a 15-minute step produces 52
near-identical cards; with it the group sees "Pá 11. 9., 12:00–13:30, volno až
do 17:00" once. `window_ends_at` carries the end of the run, which is what
tells people they could start later.

### Optimisation, concretely

- `range_agg` per participant runs **once** per request; everything after it is
  in-memory multirange algebra. That single CTE is the only table access per
  user.
- Vote tallies moved from three correlated subqueries per candidate to one
  grouped scan (`_vote_tally`). Twenty candidates: 60 index probes → 1 scan.
- `free_days` is referenced three times in the day branch, so Postgres
  materialises it and the availability solver runs once, not three times.
- The ranking formula lives in `_candidate_score` — one definition, used by
  both branches and by the `ORDER BY`.
- `create_trip` refuses a time-mode window longer than six weeks. Not a
  product limit: it is `days × slots × participants` rows, and at a 15-minute
  step a year is 35 000 slots.
- `date_votes (trip_id, slot_start)` index covers the only read path.
- Both helper functions are `revoke execute … from public`; `_vote_tally`
  re-checks membership anyway, because a security definer helper that trusts
  its caller is exactly how these leak.

### Availability is now one screen with two ways to fill it

`my_manual_busy` became `my_busy_blocks` and no longer filters to
`source_kind = 'manual'`. Importing the calendar drops its blocks straight
into the grid where they can be corrected, which matters because the calendar
is never quite right — it does not know about the dentist you have not booked
yet. Hiding the imported blocks would have made the import look like it did
nothing, and saving afterwards would have silently wiped it.

`set_manual_busy(uuid, jsonb)` replaces `set_manual_busy_days(uuid, date[])`;
a `date[]` cannot say "Tuesday between 9 and 17". Elements are
`{"day":"…"}` or `{"day":"…","from":"09:00","to":"17:00"}`, converted to
instants server-side in the **trip's** timezone.

`ConnectCalendarSheet` is now only the explain-first permission step, opened
from that screen. Trip Overview has one button, not two: making somebody pick
a path before they have seen either was a decision asked too early.

### Invite flow

Redeeming an invite now lands on `/trips/:id/availability`, not the trip
overview. Joining is not what the organiser needs from that person — their
availability is, and every screen between the tap and that answer is where the
funnel leaks. `go` builds the trip detail underneath, so Back is sensible.

### Still unverified

Written with no Flutter SDK and no database on the assistant side. Before
pushing: `dart format lib test`, `flutter analyze --fatal-infos`,
`flutter test`, `supabase db push`, then both files in `supabase/tests/`.

---

## 12. Session 4 — the invite dead end, and weather

### The invite bug was not a bug

`docs/404.html` had exactly two buttons: "Otevřít v aplikaci", which reloads
the same URL and does nothing without the Android app installed, and "Nemám
aplikaci", which went to `github.com/PatrikR9/PlanTo`. So an invitee who
wanted to say when they were free ended up reading source code. Nothing was
broken; there was simply no path from the landing page into the product.

**Fix: the web build is now deployed.** `.github/workflows/pages.yml` builds
`flutter build web --base-href /PlanTo/`, copies `docs/404.html` in as the
unknown-path handler, and publishes through GitHub Pages. The landing page's
primary button now goes to `<base>#/i/<token>` — Flutter web uses the hash URL
strategy, so the route travels in the fragment and Pages only ever has to
serve `index.html`. No SPA-redirect trick, no extra Dart.

`docs/index.html` was deleted: it was a copy of the invite page, and the
Flutter build owns that filename now.

**This changes a recorded constraint.** "Android only, Chrome is a dev target"
becomes "Android only, plus a web build that exists so an invite works before
the app is on Play". Reading the device calendar still does not work on the
web — there is no API — so those people use the manual editor, which is
exactly the case it was built for. The availability screen now says so plainly
instead of showing a button that cannot fire.

Two setup steps: repository secrets `SUPABASE_URL` and `SUPABASE_ANON_KEY`,
and Settings → Pages → Source → **GitHub Actions**. The workflow fails with a
readable message if the secrets are missing, because a prod build without a
backend throws on startup and would otherwise deploy a white screen.

### M6 — weather

The wedge was never "here is the forecast". It is "Saturday 84, Sunday 41 — go
Saturday", so the forecast is a term in the ranking, not decoration on a card.

| Piece | |
|---|---|
| `weather_daily` | cache on a **0.1° grid**, not per trip. Open-Meteo's model resolution is ~11 km, so a finer key would cost requests and buy nothing — every trip leaving Prague shares one entry |
| `_weather_score` | starts at 100, subtracts named penalties. Additive and capped so every lost point has one cause the UI can name. Returns **null** with no data |
| `_activity_profile` | 27 °C is perfect for a lake and punishing on a climb. One profile per trip, from the tags |
| `_daylight_factor` | time mode asks how much of the *slot* is in daylight (an 18:00 walk in December scores zero); day mode asks how much daylight the day has at all |
| `weather` Edge Function | the only writer, and the only thing that talks to Open-Meteo |

**The decision worth remembering: unknown is not bad.** Open-Meteo stops at 16
days and people plan further, so most candidates in a wide window have no
forecast. Dropping the missing terms would push every unknown date below every
sunny one and the screen would read "November is bad" when the truth is "we do
not know yet". So `_candidate_score` renormalises the applicable weights to sum
to 1, and an unknown date competes on what *is* known. `_weather_score`
returns null rather than 100 for the same reason — with no data every penalty
is zero, and a naive implementation would call an unknown day perfect.

**Low API usage, concretely.** `weather_request` tells the Edge Function
whether anything in range is missing or older than six hours; if not it
returns without touching Open-Meteo. Six hours because that is roughly how
often the underlying model runs. The Dates tab can be opened fifty times and
cost fifty round trips to our own function and zero to theirs.

**Licence.** `api.open-meteo.com` is free for **non-commercial** use. Before
PlanTo takes a euro this must point at a self-hosted instance on the VPS. One
line changes — the URL is already `Deno.env.get("OPEN_METEO_URL")`.

### Unverified

No Flutter SDK, no database and no Deno on the assistant side. In particular
the exact Open-Meteo daily variable names are from memory; the function passes
their own `reason` string straight through, so one run says whether any of
them is wrong.

    dart format lib test
    flutter analyze --fatal-infos
    flutter test
    supabase db push
    supabase functions deploy weather
    psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/weather_test.sql

### Two traps hit on the first push (31 July / 1 Aug)

1. **`CREATE OR REPLACE FUNCTION` cannot change a return type**, and for
   `RETURNS TABLE` the output columns *are* the return type. `trip_candidates`
   gained seven weather columns, so Postgres refused. Fixed with an explicit
   `DROP FUNCTION IF EXISTS trip_candidates(uuid, int)` first — and the grant
   has to be reissued, because dropping takes it with it.

   Worth knowing because the failure is misleading: `supabase db push` reports
   it as "failed to execute statement" with no reason, and the statement it
   prints is 200 lines of solver that looks like the problem.

2. **Adding a parameter with a default creates an ambiguous overload.**
   `_candidate_score` went from four arguments to six with the last two
   defaulted, which made every existing four-argument call resolve to two
   candidate functions. The old signature has to be dropped, not left to rot.
