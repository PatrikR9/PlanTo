-- M6 weather: scoring, daylight, and what happens past the forecast horizon.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/weather_test.sql
--
-- The scoring numbers themselves are judgement calls and will get tuned. What
-- must not drift is the shape: unknown never scores as bad, activity profiles
-- disagree with each other, and a missing forecast renormalises rather than
-- zeroing the term.

begin;
set local role postgres;

-- ---------------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------------
do $$
declare
  perfect int;
  rainy   int;
  stormy  int;
  unknown int;
begin
  -- A dry, sunny, 20 °C day for a city trip is close to full marks.
  perfect := _weather_score('city', 21, 21, 0, 0, 10, 0, 0, 36000, 40000);
  assert perfect >= 90, format('a perfect city day scored %s', perfect);

  -- Same day, an 80 percent chance of rain and 8 mm of it.
  rainy := _weather_score('city', 21, 21, 8, 80, 10, 0, 61, 5000, 40000);
  assert rainy < perfect - 40,
    format('rain should cost heavily: perfect=%s rainy=%s', perfect, rainy);

  -- A thunderstorm is a safety matter above a ridge, not a comfort one.
  stormy := _weather_score('hiking', 21, 21, 5, 70, 30, 0, 95, 5000, 40000);
  assert stormy < 35, format('a thunderstorm scored %s, expected well under 35',
                             stormy);

  -- THE important one. No forecast row means every argument is null, every
  -- penalty is zero, and a naive implementation returns 100 — the single most
  -- misleading number this function could produce.
  unknown := _weather_score('city', null, null, null, null, null, null,
                            null, null, null);
  assert unknown is null, format('unknown weather scored %s, must be null',
                                 unknown);

  raise notice 'weather scoring: OK';
end $$;

-- Activity profiles must actually disagree; otherwise the parameter is
-- decoration.
do $$
declare
  lake_cold  int;
  hike_cold  int;
  lake_hot   int;
  hike_hot   int;
begin
  -- 13 °C, dry and sunny.
  lake_cold := _weather_score('lake',   13, 13, 0, 0, 5, 0, 0, 36000, 40000);
  hike_cold := _weather_score('hiking', 13, 13, 0, 0, 5, 0, 0, 36000, 40000);
  assert hike_cold > lake_cold + 15,
    format('13 C suits walking far better than swimming: hike=%s lake=%s',
           hike_cold, lake_cold);

  -- 31 °C, dry and sunny.
  lake_hot := _weather_score('lake',   31, 31, 0, 0, 5, 0, 0, 36000, 40000);
  hike_hot := _weather_score('hiking', 31, 31, 0, 0, 5, 0, 0, 36000, 40000);
  assert lake_hot > hike_hot + 15,
    format('31 C suits swimming far better than climbing: lake=%s hike=%s',
           lake_hot, hike_hot);

  raise notice 'activity profiles: OK';
end $$;

-- ---------------------------------------------------------------------------
-- Daylight
-- ---------------------------------------------------------------------------
do $$
declare f numeric;
begin
  -- Time mode: an evening slot entirely after sunset is worth nothing, and
  -- that is the point of having the term at all.
  f := _daylight_factor(
    '2026-12-06 07:59+01', '2026-12-06 15:59+01',
    '2026-12-06 18:00+01', '2026-12-06 19:30+01', true);
  assert f = 0, format('a slot after dark scored %s', f);

  -- Fully inside daylight.
  f := _daylight_factor(
    '2026-07-06 05:00+02', '2026-07-06 21:00+02',
    '2026-07-06 12:00+02', '2026-07-06 13:30+02', true);
  assert f = 1, format('a midday slot scored %s', f);

  -- Half in, half out.
  f := _daylight_factor(
    '2026-07-06 05:00+02', '2026-07-06 21:00+02',
    '2026-07-06 20:00+02', '2026-07-06 22:00+02', true);
  assert f > 0.4 and f < 0.6, format('a slot straddling sunset scored %s', f);

  -- Day mode has no clock to compare against, so it asks how much usable
  -- daylight the day has at all, against a 12-hour ideal.
  f := _daylight_factor('2026-07-06 05:00+02', '2026-07-06 21:00+02',
                        null, null, false);
  assert f = 1, format('a 16-hour summer day scored %s', f);
  f := _daylight_factor('2026-12-06 08:00+01', '2026-12-06 16:00+01',
                        null, null, false);
  assert f > 0.6 and f < 0.7, format('an 8-hour winter day scored %s', f);

  -- No sunrise data is unknown, not midnight.
  assert _daylight_factor(null, null, null, null, false) is null,
    'missing sun times must be null';

  raise notice 'daylight: OK';
end $$;

-- ---------------------------------------------------------------------------
-- Ranking with and without a forecast
-- ---------------------------------------------------------------------------
do $$
declare
  known_good numeric;
  known_bad  numeric;
  unknown    numeric;
begin
  -- Same availability, same weekend, three states of knowledge.
  known_good := _candidate_score(4, 4, true, false, 90, 1.0);
  known_bad  := _candidate_score(4, 4, true, false, 10, 1.0);
  unknown    := _candidate_score(4, 4, true, false, null, null);

  assert known_good > known_bad,
    'good weather must outrank bad on an otherwise identical day';

  -- The whole reason for renormalising. Open-Meteo stops at 16 days and
  -- people plan further, so most candidates in a wide window have no forecast.
  -- If the missing terms were simply dropped, every unknown date would sink
  -- below every sunny one and the screen would read "November is bad" when
  -- the truth is "we do not know yet".
  assert unknown > known_bad,
    format('an unknown forecast (%s) must beat a known bad one (%s)',
           unknown, known_bad);
  assert unknown < known_good,
    format('an unknown forecast (%s) must not beat a known good one (%s)',
           unknown, known_good);

  -- A fully free, sunny weekend day is the best a candidate can be.
  assert _candidate_score(4, 4, true, true, 100, 1.0) = 1.0,
    'the ceiling should be exactly 1';

  -- Nobody free, everything else perfect: availability is 45 % of the weight.
  assert _candidate_score(0, 4, true, true, 100, 1.0) < 0.6,
    'availability must dominate';

  raise notice 'ranking with and without a forecast: OK';
end $$;

-- ---------------------------------------------------------------------------
-- End to end: the forecast reaches the candidates
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at,
                        created_at, updated_at)
values ('a0a0a0a0-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'wx@test.cz', now(), now(), now());

insert into profiles (id, display_name)
values ('a0a0a0a0-0000-0000-0000-000000000001', 'Meteorolog')
on conflict (id) do nothing;

-- Fixed dates, not current_date + n. Two plain weekdays in September, so the
-- weekend and holiday terms are identical for both and the forecast is the
-- only thing separating them. Relative dates would make the ordering
-- assertion below pass or fail depending on the day the suite happens to run.
-- Prague rounds to 50.1 / 14.4 on the cache grid.
insert into trips (id, created_by, title, origin_label, origin_point,
                   date_window, duration_days, timezone, granularity,
                   activity_tags)
values (
  'b0b0b0b0-0000-0000-0000-000000000001',
  'a0a0a0a0-0000-0000-0000-000000000001',
  'Weather', 'Praha', st_point(14.42, 50.08)::geography,
  tstzrange('2026-09-16 00:00+02', '2026-09-18 00:00+02'),
  1, 'Europe/Prague', 'day', array['city']
);

-- `calendar_shared` je od M15 podmínka pro započítání do dostupnosti:
-- kdo ji nezadal, není ve free_count ani v total_count. Fixtura to
-- proto musí říct nahlas — dřív stačilo vložit busy_intervals.
insert into trip_participants (trip_id, user_id, role, calendar_shared)
values ('b0b0b0b0-0000-0000-0000-000000000001',
        'a0a0a0a0-0000-0000-0000-000000000001', 'organiser', true);

-- The 16th is glorious; the 17th is a washout.
insert into weather_daily (lat, lon, day, weather_code, temp_max, apparent_max,
                           precip_mm, precip_prob, wind_gust_kmh, snowfall_cm,
                           sunrise, sunset, daylight_seconds, sunshine_seconds)
values
  (50.1, 14.4, date '2026-09-16', 0, 22, 22, 0, 0, 8, 0,
   '2026-09-16 06:45+02', '2026-09-16 19:20+02', 45300, 40000),
  (50.1, 14.4, date '2026-09-17', 65, 12, 10, 14, 95, 45, 0,
   '2026-09-17 06:47+02', '2026-09-17 19:18+02', 45060, 3000);

set local role authenticated;
set local request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000000001"}';

do $$
declare
  good record;
  bad  record;
  first_day record;
begin
  select * into good
  from trip_candidates('b0b0b0b0-0000-0000-0000-000000000001', 50)
  where starts_at = ('2026-09-16'::timestamp) at time zone 'Europe/Prague';
  select * into bad
  from trip_candidates('b0b0b0b0-0000-0000-0000-000000000001', 50)
  where starts_at = ('2026-09-17'::timestamp) at time zone 'Europe/Prague';

  assert good.weather_score is not null, 'the forecast must reach the card';
  assert good.weather_score > bad.weather_score + 30,
    format('sunny=%s wet=%s', good.weather_score, bad.weather_score);
  assert good.weather_code = 0 and good.temp_max = 22,
    'the raw values must come through for the glyph and the label';
  assert bad.precip_prob = 95, 'precipitation probability must come through';

  -- The point of the whole milestone: weather changes the order, not just the
  -- decoration. Both days are equally free, so only the forecast separates
  -- them.
  select * into first_day
  from trip_candidates('b0b0b0b0-0000-0000-0000-000000000001', 50) limit 1;
  assert first_day.starts_at =
    ('2026-09-16'::timestamp) at time zone 'Europe/Prague',
    'the sunny day must rank first';

  raise notice 'weather reaches the ranking: OK';
end $$;

rollback;
