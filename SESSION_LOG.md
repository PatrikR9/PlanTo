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
