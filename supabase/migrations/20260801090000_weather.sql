-- ============================================================================
-- M6 — weather.
--
-- The wedge is not "here is the forecast". It is "Saturday scores 84, Sunday
-- 41 — go Saturday". So the forecast is not a decoration on the card, it is a
-- term in the ranking, and it is computed by rules rather than by a model:
-- the free tier calls no AI, and a number a user cannot reproduce is a number
-- they will not trust.
--
-- LICENCE — READ BEFORE MONETISING. Open-Meteo's free API is licensed for
-- NON-COMMERCIAL use. The moment PlanTo takes money this must move to a
-- self-hosted Open-Meteo (the code is AGPL-3.0, the data is open) on the
-- planned Hetzner VPS. Nothing in the schema or the scoring changes when it
-- does — only the URL inside the Edge Function. See
-- PlanTo_costs_and_dependencies.md section C1.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The cache
-- ---------------------------------------------------------------------------
-- Keyed on a rounded coordinate grid rather than on a trip. Open-Meteo's model
-- resolution is about 11 km, so a finer key would buy nothing and cost a
-- request: rounding to 0.1° means every trip leaving Prague shares one cache
-- entry. That is the whole low-API-usage story.
create table if not exists weather_daily (
  lat        numeric(5,1) not null,
  lon        numeric(5,1) not null,
  day        date not null,

  weather_code       int,
  temp_max           numeric(4,1),
  temp_min           numeric(4,1),
  apparent_max       numeric(4,1),
  precip_mm          numeric(5,1),
  precip_prob        int,
  wind_gust_kmh      numeric(5,1),
  snowfall_cm        numeric(4,1),
  uv_index           numeric(3,1),
  sunrise            timestamptz,
  sunset             timestamptz,
  daylight_seconds   int,
  sunshine_seconds   int,

  fetched_at timestamptz not null default now(),
  primary key (lat, lon, day)
);

create index if not exists weather_daily_fetched_idx
  on weather_daily (fetched_at);

alter table weather_daily enable row level security;

-- Public data about the sky. There is nothing here to protect, and letting
-- the weather detail screen read a row directly saves an RPC.
drop policy if exists weather_read on weather_daily;
create policy weather_read on weather_daily for select using (true);
-- Writes are service_role only: the Edge Function is the single writer.

comment on table weather_daily is
  'Forecast cache on a 0.1-degree grid. Written only by the `weather` Edge '
  'Function. Source: Open-Meteo — free tier is NON-COMMERCIAL, self-host '
  'before charging money.';

-- ---------------------------------------------------------------------------
-- 2. Activity profile
-- ---------------------------------------------------------------------------
-- What counts as good weather depends on what you are doing. 24 °C and clear
-- is perfect for a lake and unpleasant for a long climb; 12 °C and dry is
-- fine for a castle and miserable for swimming. One profile per trip, derived
-- from the tags, in priority order — a trip tagged both lake and hiking is
-- planned around the water.
create or replace function _activity_profile(p_tags text[])
returns text language sql immutable as $$
  select case
    when 'lake'      = any(p_tags) then 'lake'
    when 'hiking'    = any(p_tags) then 'hiking'
    when 'viewpoint' = any(p_tags) then 'hiking'
    when 'festival'  = any(p_tags) then 'outdoor'
    when 'city'      = any(p_tags) then 'city'
    when 'museum'    = any(p_tags) then 'indoor'
    when 'cafe'      = any(p_tags) then 'indoor'
    else 'general'
  end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The scoring engine
-- ---------------------------------------------------------------------------
-- Starts at 100 and subtracts. Penalties are additive and capped, which keeps
-- the result explainable: every point lost has one named cause, and the UI can
-- show that cause as a chip. A multiplicative model would score better on a
-- benchmark nobody is running and be impossible to justify to a user.
--
-- Returns null when there is no forecast row. Null means "unknown", never
-- "bad" — see _candidate_score, which renormalises rather than assuming.
create or replace function _weather_score(
  p_profile      text,
  p_temp_max     numeric,
  p_apparent_max numeric,
  p_precip_mm    numeric,
  p_precip_prob  int,
  p_wind_gust    numeric,
  p_snow_cm      numeric,
  p_code         int,
  p_sunshine_s   int,
  p_daylight_s   int
)
returns int
language sql
immutable
as $$
  with felt as (
    -- Apparent temperature is what a person experiences; fall back to the
    -- dry-bulb figure when the API did not send one.
    select coalesce(p_apparent_max, p_temp_max) as t
  ),
  ideal as (
    select case p_profile
             when 'lake'   then 27.0
             when 'hiking' then 19.0
             when 'city'   then 21.0
             when 'indoor' then 18.0
             else 21.0
           end as target,
           -- Penalty per degree below / above the comfortable band. Swimming
           -- punishes cold hard and heat barely; walking uphill is the
           -- reverse.
           case p_profile
             when 'lake'   then 3.5
             when 'hiking' then 1.4
             when 'indoor' then 0.4
             else 1.6
           end as cold_penalty,
           case p_profile
             when 'lake'   then 0.4
             when 'hiking' then 2.4
             when 'indoor' then 0.4
             else 1.6
           end as heat_penalty,
           -- Rain matters less if the plan was indoors anyway.
           case p_profile when 'indoor' then 0.35 else 1.0 end as wet_weight
    from felt
  ),
  penalties as (
    select
      -- Probability of rain, up to 30 points. The chance of getting wet is
      -- what changes a decision; the amount decides how much.
      least(30.0, coalesce(p_precip_prob, 0) * 0.30) as p_prob,
      -- Amount, up to 25. 1 mm is nothing, 10 mm is a day indoors.
      least(25.0, coalesce(p_precip_mm, 0) * 2.5)    as p_amount,
      -- Thunderstorms (WMO 95/96/99) are a safety matter above a mountain,
      -- not a comfort one, so this is deliberately heavy-handed.
      case when p_code in (95, 96, 99) then 30.0 else 0.0 end as p_storm,
      -- Gusts below 40 km/h are weather; above that they are a problem.
      greatest(0.0, least(20.0, (coalesce(p_wind_gust, 0) - 40) * 0.7)) as p_wind,
      least(20.0, coalesce(p_snow_cm, 0) * 4.0) as p_snow,
      -- Grey but dry still costs something: nobody drives two hours for a
      -- viewpoint in cloud. Capped low because it is a preference, not a
      -- problem.
      case
        when p_sunshine_s is null or p_daylight_s is null or p_daylight_s = 0
          then 0.0
        else least(12.0, (1 - (p_sunshine_s::numeric / p_daylight_s)) * 12.0)
      end as p_grey,
      (select case
                when t < target then (target - t) * cold_penalty
                else (t - target) * heat_penalty
              end
       from felt, ideal) as p_temp,
      (select wet_weight from ideal) as wet
  )
  select case
    -- No forecast row means unknown, and unknown must not look like a
    -- perfect day. Every penalty above would be zero and the score would
    -- come out 100 — the single most misleading number this function could
    -- return.
    when p_temp_max is null and p_apparent_max is null and p_code is null
      then null
    else greatest(0, least(100, round(
        100
      - (p_prob + p_amount + p_storm) * wet
      - p_wind
      - p_snow
      - p_grey
      - least(35.0, p_temp)
    )))::int
  end
  from penalties;
$$;

comment on function _weather_score is
  'Deterministic 0-100 weather quality for an activity profile. No model, no '
  'AI: every point lost has one named cause so the UI can explain it.';

-- ---------------------------------------------------------------------------
-- 4. Daylight
-- ---------------------------------------------------------------------------
-- Its own term, because "we will be descending in the dark" is a different
-- objection from "it will rain" and a group weighs them differently.
--
-- Time mode asks how much of the actual slot is in daylight — an 18:00 walk
-- in December scores zero and should. Day mode has no clock to compare, so it
-- asks how much usable daylight the day has at all, against a 12-hour ideal.
create or replace function _daylight_factor(
  p_sunrise  timestamptz,
  p_sunset   timestamptz,
  p_start    timestamptz,
  p_end      timestamptz,
  p_timed    boolean
)
returns numeric
language sql
immutable
as $$
  select case
    when p_sunrise is null or p_sunset is null then null
    when not p_timed then
      least(1.0, extract(epoch from (p_sunset - p_sunrise)) / 43200.0)
    when p_end <= p_start then null
    else
      greatest(0.0, least(1.0,
        extract(epoch from (
          least(p_end, p_sunset) - greatest(p_start, p_sunrise)
        )) / extract(epoch from (p_end - p_start))
      ))
  end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Ranking
-- ---------------------------------------------------------------------------
-- Weights from architecture section 11.3: availability .45, weekend .15,
-- holiday .10, weather .20, daylight .10.
--
-- The interesting case is a missing forecast. Open-Meteo goes 16 days out and
-- people plan further than that, so most candidates in a wide window have no
-- weather at all. Dropping the terms would push every unknown-weather date
-- below every sunny one, which reads as "November is bad" when the truth is
-- "we do not know yet". So the applicable weights are renormalised to sum to
-- 1 and an unknown date competes on what IS known.
create or replace function _candidate_score(
  p_free     int,
  p_total    int,
  p_weekend  boolean,
  p_holiday  boolean,
  p_weather  int     default null,
  p_daylight numeric default null
)
returns numeric
language sql
immutable
as $$
  with w as (
    select 0.45::numeric as avail,
           0.15::numeric as weekend,
           0.10::numeric as holiday,
           case when p_weather  is null then 0 else 0.20 end::numeric as wx,
           case when p_daylight is null then 0 else 0.10 end::numeric as light
  )
  select round(
    (
        w.avail   * coalesce(p_free::numeric / nullif(p_total, 0), 0)
      + w.weekend * (case when p_weekend then 1 else 0 end)
      + w.holiday * (case when p_holiday then 1 else 0 end)
      + w.wx      * (coalesce(p_weather, 0)::numeric / 100)
      + w.light   * coalesce(p_daylight, 0)
    ) / (w.avail + w.weekend + w.holiday + w.wx + w.light)
  , 4)
  from w;
$$;

-- The four-argument form is gone; every caller now passes weather. Dropped
-- explicitly because adding parameters with defaults would leave both
-- signatures resolvable and a forgotten call site would silently keep
-- ranking without the forecast.
drop function if exists _candidate_score(int, int, boolean, boolean);
revoke execute on function
  _candidate_score(int, int, boolean, boolean, int, numeric) from public;
revoke execute on function _weather_score(
  text, numeric, numeric, numeric, int, numeric, numeric, int, int, int
) from public;
revoke execute on function
  _daylight_factor(timestamptz, timestamptz, timestamptz, timestamptz, boolean)
  from public;
revoke execute on function _activity_profile(text[]) from public;

-- ---------------------------------------------------------------------------
-- 6. Where the forecast is for
-- ---------------------------------------------------------------------------
-- The destination if the group has picked one, otherwise the origin. Not a
-- fudge: for an undecided trip the origin is the only honest guess, and in
-- Central Europe two towns 80 km apart share a forecast far more often than
-- not. Once M9 picks a destination this starts answering the right question
-- with no further change.
create or replace function _trip_weather_point(p_trip uuid)
returns table (lat numeric, lon numeric)
language sql
security definer
set search_path = public
stable
as $$
  select round(st_y(coalesce(d.point, t.origin_point)::geometry)::numeric, 1),
         round(st_x(coalesce(d.point, t.origin_point)::geometry)::numeric, 1)
  from trips t
  left join destinations d on d.id = t.destination_id
  where t.id = p_trip and is_trip_member(p_trip);
$$;

revoke execute on function _trip_weather_point(uuid) from public;

-- ---------------------------------------------------------------------------
-- 7. Candidates, now weather-aware
-- ---------------------------------------------------------------------------
-- Dropped first, not replaced. RETURNS TABLE columns ARE the return type, and
-- CREATE OR REPLACE cannot change one — this gains seven columns, so Postgres
-- refuses with "cannot change return type of existing function".
drop function if exists trip_candidates(uuid, int);

create function trip_candidates(p_trip uuid, p_limit int default 20)
returns table (
  starts_at      timestamptz,
  ends_at        timestamptz,
  window_ends_at timestamptz,
  free_count     int,
  total_count    int,
  free_user_ids  uuid[],
  busy_user_ids  uuid[],
  is_weekend     boolean,
  is_holiday     boolean,
  score          numeric,
  yes_count      int,
  maybe_count    int,
  no_count       int,
  my_vote        text,
  is_locked      boolean,
  weather_score  int,
  weather_code   int,
  temp_max       numeric,
  precip_prob    int,
  wind_gust_kmh  numeric,
  sunrise        timestamptz,
  sunset         timestamptz
)
language plpgsql
security definer
set search_path = public
stable
as $$
#variable_conflict use_column
-- ^ RETURNS TABLE turns every output column into a plpgsql variable, and
-- several of them are also column names in the CTEs below. Everything here is
-- alias-qualified, but this makes the resolution rule explicit rather than
-- relying on that discipline holding.
declare
  t          trips%rowtype;
  v_slot     interval;
  v_step     interval;
  v_duration int;
  v_last_day date;
  v_locked   timestamptz;
  v_profile  text;
  v_lat      numeric;
  v_lon      numeric;
begin
  select * into t from trips where id = p_trip;
  if not found or not is_trip_member(p_trip) then
    return;                       -- a non-member gets no rows, not an error
  end if;

  v_duration := coalesce(t.duration_days, 1);
  v_slot     := make_interval(mins => coalesce(t.slot_minutes, 120));
  v_step     := make_interval(mins => t.slot_step_minutes);
  v_last_day := upper(t.date_window)::date;
  v_locked   := lower(t.locked_range);
  v_profile  := _activity_profile(t.activity_tags);

  select p.lat, p.lon into v_lat, v_lon from _trip_weather_point(p_trip) p;

  if t.granularity = 'day' then
    return query
    with free_days as (
      select g.day, g.free_user_ids, g.busy_user_ids,
             g.total_count, g.is_weekend, g.is_holiday
      from group_free_days(p_trip) g
    ),
    -- A multi-day trip is only feasible if EVERY day of the block works for
    -- the person. Evaluating just the first day would propose a Saturday for
    -- a three-day trip when two of those people work on the Monday.
    per_user as (
      select s.day as start_day, u.user_id,
             bool_and(u.user_id = any(f.free_user_ids)) as is_free,
             count(*) as days_covered
      from free_days s
      cross join lateral (
        select unnest(s.free_user_ids || s.busy_user_ids) as user_id
      ) u
      join free_days f
        on f.day >= s.day and f.day < s.day + v_duration
      where s.day + v_duration - 1 <= v_last_day
      group by s.day, u.user_id
    ),
    blocks as (
      select p.start_day,
             count(*) filter (where p.is_free and p.days_covered = v_duration)::int
               as free_count,
             count(*)::int as total_count,
             coalesce(array_agg(p.user_id) filter
               (where p.is_free and p.days_covered = v_duration), '{}') as free_ids,
             coalesce(array_agg(p.user_id) filter
               (where not (p.is_free and p.days_covered = v_duration)), '{}') as busy_ids
      from per_user p
      group by p.start_day
    ),
    scored as (
      select
        (b.start_day::timestamp) at time zone t.timezone as starts_at,
        ((b.start_day + v_duration)::timestamp) at time zone t.timezone as ends_at,
        b.free_count, b.total_count, b.free_ids, b.busy_ids,
        f.is_weekend, f.is_holiday,
        _weather_score(
          v_profile, w.temp_max, w.apparent_max, w.precip_mm, w.precip_prob,
          w.wind_gust_kmh, w.snowfall_cm, w.weather_code,
          w.sunshine_seconds, w.daylight_seconds
        ) as wx,
        _daylight_factor(w.sunrise, w.sunset,
                         null::timestamptz, null::timestamptz, false) as light,
        w.weather_code, w.temp_max, w.precip_prob, w.wind_gust_kmh,
        w.sunrise, w.sunset
      from blocks b
      join free_days f on f.day = b.start_day
      -- The forecast for the FIRST day of the block. A three-day trip is
      -- decided on the day you leave; scoring the average would hide a
      -- washed-out Saturday behind two fine days.
      left join weather_daily w
        on w.lat = v_lat and w.lon = v_lon and w.day = b.start_day
    )
    select
      s.starts_at, s.ends_at, s.ends_at,
      s.free_count, s.total_count, s.free_ids, s.busy_ids,
      s.is_weekend, s.is_holiday,
      _candidate_score(s.free_count, s.total_count, s.is_weekend, s.is_holiday,
                       s.wx, s.light),
      coalesce(v.yes_count, 0), coalesce(v.maybe_count, 0),
      coalesce(v.no_count, 0), v.my_vote,
      v_locked is not null and v_locked = s.starts_at,
      s.wx, s.weather_code, s.temp_max, s.precip_prob, s.wind_gust_kmh,
      s.sunrise, s.sunset
    from scored s
    left join _vote_tally(p_trip) v on v.slot_start = s.starts_at
    order by
      (v_locked is not null and v_locked = s.starts_at) desc,
      _candidate_score(s.free_count, s.total_count, s.is_weekend, s.is_holiday,
                       s.wx, s.light) desc,
      s.starts_at
    limit p_limit;

  else
    return query
    with participants as (
      select tp.user_id
      from trip_participants tp
      where tp.trip_id = p_trip and tp.status <> 'declined'
    ),
    busy_by_user as (
      select p.user_id,
             coalesce(range_agg(b.period), '{}'::tstzmultirange) as mr
      from participants p
      left join busy_intervals b
        on b.user_id = p.user_id and b.trip_id = p_trip
      group by p.user_id
    ),
    day_windows as (
      select d::date as day,
             (d::date + t.day_start) at time zone t.timezone as win_start,
             (d::date + t.day_end)   at time zone t.timezone as win_end
      from generate_series(
             lower(t.date_window)::date,
             upper(t.date_window)::date,
             interval '1 day'
           ) d
    ),
    slots as (
      select dw.day, s
      from day_windows dw
      cross join lateral generate_series(
        dw.win_start, dw.win_end - v_slot, v_step
      ) s
    ),
    slot_state as (
      select sl.day, sl.s,
             count(*) filter (
               where not (bu.mr && tstzrange(sl.s, sl.s + v_slot, '[)'))
             )::int as free_count,
             count(*)::int as total_count,
             coalesce(array_agg(bu.user_id order by bu.user_id) filter (
               where not (bu.mr && tstzrange(sl.s, sl.s + v_slot, '[)'))
             ), '{}') as free_ids,
             coalesce(array_agg(bu.user_id order by bu.user_id) filter (
               where bu.mr && tstzrange(sl.s, sl.s + v_slot, '[)')
             ), '{}') as busy_ids
      from slots sl
      cross join busy_by_user bu
      group by sl.day, sl.s
    ),
    -- Gaps and islands. free_ids is aggregated in a stable order above so
    -- that "the same people" compares equal.
    marked as (
      select ss.*,
             case
               when lag(ss.free_ids) over w is distinct from ss.free_ids then 1
               when lag(ss.s) over w is null then 1
               when ss.s <> lag(ss.s) over w + v_step then 1
               else 0
             end as new_run
      from slot_state ss
      window w as (partition by ss.day order by ss.s)
    ),
    runs as (
      select m.*,
             sum(m.new_run) over (partition by m.day order by m.s) as run_id
      from marked m
    ),
    merged as (
      -- Every row in a run has, by construction, the same free set — that is
      -- what defines the run — so min() is just "take the one value".
      -- array_agg(...)[1] would silently return null here: aggregating arrays
      -- builds a 2-D array, and subscripting one element of that is not a row.
      select r.day,
             min(r.s) as starts_at,
             max(r.s) + v_slot as window_ends_at,
             min(r.free_count) as free_count,
             min(r.total_count) as total_count,
             min(r.free_ids) as free_ids,
             min(r.busy_ids) as busy_ids
      from runs r
      group by r.day, r.run_id
    ),
    scored as (
      select
        m.day, m.starts_at, m.starts_at + v_slot as ends_at, m.window_ends_at,
        m.free_count, m.total_count, m.free_ids, m.busy_ids,
        extract(isodow from m.day) >= 6 as is_weekend,
        exists (select 1 from holidays h
                 where h.date = m.day and h.country = 'CZ') as is_holiday,
        _weather_score(
          v_profile, w.temp_max, w.apparent_max, w.precip_mm, w.precip_prob,
          w.wind_gust_kmh, w.snowfall_cm, w.weather_code,
          w.sunshine_seconds, w.daylight_seconds
        ) as wx,
        _daylight_factor(
          w.sunrise, w.sunset, m.starts_at, m.starts_at + v_slot, true
        ) as light,
        w.weather_code, w.temp_max, w.precip_prob, w.wind_gust_kmh,
        w.sunrise, w.sunset
      from merged m
      left join weather_daily w
        on w.lat = v_lat and w.lon = v_lon and w.day = m.day
    )
    select
      s.starts_at, s.ends_at, s.window_ends_at,
      s.free_count, s.total_count, s.free_ids, s.busy_ids,
      s.is_weekend, s.is_holiday,
      _candidate_score(s.free_count, s.total_count, s.is_weekend, s.is_holiday,
                       s.wx, s.light),
      coalesce(v.yes_count, 0), coalesce(v.maybe_count, 0),
      coalesce(v.no_count, 0), v.my_vote,
      v_locked is not null and v_locked = s.starts_at,
      s.wx, s.weather_code, s.temp_max, s.precip_prob, s.wind_gust_kmh,
      s.sunrise, s.sunset
    from scored s
    left join _vote_tally(p_trip) v on v.slot_start = s.starts_at
    order by
      (v_locked is not null and v_locked = s.starts_at) desc,
      _candidate_score(s.free_count, s.total_count, s.is_weekend, s.is_holiday,
                       s.wx, s.light) desc,
      s.starts_at
    limit p_limit;
  end if;
end;
$$;

grant execute on function trip_candidates(uuid, int) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. What the Edge Function needs to know
-- ---------------------------------------------------------------------------
-- Returned in one call so the function does not have to reimplement the
-- rounding rule or the forecast horizon, and so a member's own JWT is enough
-- to ask: RLS on trips means a non-member gets nothing.
--
-- `stale` is the whole point. If it is false the Edge Function returns
-- immediately without touching Open-Meteo, which is what keeps the request
-- count near zero however often the Dates tab is opened.
create or replace function weather_request(p_trip uuid)
returns table (
  lat        numeric,
  lon        numeric,
  tz         text,
  from_day   date,
  to_day     date,
  stale      boolean
)
language sql
security definer
set search_path = public
stable
as $$
  with p as (select * from _trip_weather_point(p_trip)),
  bounds as (
    select
      t.timezone as tz,
      greatest(lower(t.date_window)::date, current_date) as from_day,
      -- Open-Meteo forecasts 16 days. Asking for more returns nothing useful
      -- and there is no honest way to fill the gap, so we do not pretend.
      least(upper(t.date_window)::date, current_date + 15) as to_day
    from trips t
    where t.id = p_trip and is_trip_member(p_trip)
  )
  select p.lat, p.lon, b.tz, b.from_day, b.to_day,
         -- Stale if anything in range is missing or older than six hours.
         -- Six because that is roughly how often the underlying model runs;
         -- refreshing faster would fetch the same numbers again.
         (b.to_day >= b.from_day) and exists (
           select 1
           from generate_series(b.from_day, b.to_day, interval '1 day') d
           where not exists (
             select 1 from weather_daily w
             where w.lat = p.lat and w.lon = p.lon
               and w.day = d::date
               and w.fetched_at > now() - interval '6 hours'
           )
         )
  from p, bounds b;
$$;

grant execute on function weather_request(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Guardrail
-- ---------------------------------------------------------------------------
-- Same check as every migration that adds a table. It runs again here so that
-- forgetting RLS fails the push rather than a code review.
do $$
declare unprotected text;
begin
  select string_agg(c.relname, ', ')
    into unprotected
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'r'
    and not c.relrowsecurity
    and c.oid not in (
      select d.objid from pg_depend d
      where d.deptype = 'e' and d.classid = 'pg_class'::regclass
    );

  if unprotected is not null then
    raise exception 'Tables without RLS: %', unprotected;
  end if;
end $$;
