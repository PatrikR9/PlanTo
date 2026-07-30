-- ============================================================================
-- The availability solver. Architecture sections 9.3 and 11.3.
--
-- This is the core of the product and the reason the backend is Postgres:
-- "when is this group free" is set algebra over time ranges, which Postgres
-- does natively with multiranges. In a document store this would run in Dart
-- on every device, on every change.
--
-- Design note — why days rather than arbitrary intervals:
-- A generic interval intersection produces mathematically correct but useless
-- answers ("everyone is free 02:10-04:35"). Trips are planned in days, so the
-- unit here is a usable daytime window per calendar date, and a participant
-- counts as free for a date if enough of that window is unblocked. This also
-- makes k-of-n a natural result instead of a special case.
-- ============================================================================

-- Total hours covered by a multirange.
create or replace function multirange_hours(mr tstzmultirange)
returns numeric language sql immutable as $$
  select coalesce(
    sum(extract(epoch from (upper(r) - lower(r))) / 3600.0),
    0
  )::numeric
  from unnest(mr) as r;
$$;

-- Per-date availability for a trip.
--
-- p_min_free_hours: how much of the usable day must be unblocked for a
--   participant to count as free. 6 is a sensible default for a day trip.
-- p_day_start / p_day_end: the usable daytime window in the trip's timezone.
--   Busy blocks outside it (a 22:00 dinner) correctly do not disqualify a day.
create or replace function group_free_days(
  p_trip           uuid,
  p_min_free_hours numeric default 6,
  p_day_start      time default '07:00',
  p_day_end        time default '21:00'
)
returns table (
  day           date,
  free_count    int,
  total_count   int,
  free_user_ids uuid[],
  busy_user_ids uuid[],
  is_weekend    boolean,
  is_holiday    boolean
)
language sql
security definer            -- reads busy_intervals, which nobody may SELECT
set search_path = public
stable
as $$
  with trip as (
    -- SECURITY: this function is `security definer` so it can read
    -- busy_intervals, which bypasses RLS. The membership check therefore has
    -- to be explicit and inside the function -- without it any authenticated
    -- user could learn any group's schedule by guessing a trip id.
    -- An empty CTE cascades to zero rows, so a non-member gets nothing.
    select id, date_window, timezone, origin_point
    from trips
    where id = p_trip
      and is_trip_member(id)
  ),
  participants as (
    select tp.user_id
    from trip_participants tp
    join trip on trip.id = tp.trip_id      -- inherits the membership guard
    where tp.status <> 'declined'
  ),
  days as (
    select generate_series(
             lower(trip.date_window)::date,
             upper(trip.date_window)::date,
             interval '1 day'
           )::date as day,
           trip.timezone
    from trip
  ),
  -- The usable daytime window for each candidate date, in the trip's own
  -- timezone (so a trip planned from Prague behaves correctly in summer time).
  day_windows as (
    select days.day,
           tstzrange(
             (days.day + p_day_start) at time zone days.timezone,
             (days.day + p_day_end)   at time zone days.timezone,
             '[)'
           ) as win
    from days
  ),
  -- One multirange of busy time per participant. LEFT JOIN so a participant
  -- who has not connected a calendar yet is treated as fully free rather than
  -- silently dropped -- they will show up as free and can be nudged.
  busy_by_user as (
    select p.user_id,
           coalesce(range_agg(b.period), '{}'::tstzmultirange) as mr
    from participants p
    left join busy_intervals b
      on b.user_id = p.user_id
     and b.trip_id = p_trip
    group by p.user_id
  ),
  evaluated as (
    select dw.day,
           bu.user_id,
           multirange_hours(multirange(dw.win)) -
           multirange_hours(bu.mr * multirange(dw.win)) as free_hours
    from day_windows dw
    cross join busy_by_user bu
  )
  select
    e.day,
    count(*) filter (where e.free_hours >= p_min_free_hours)::int as free_count,
    count(*)::int                                                as total_count,
    -- array_agg with FILTER yields NULL, not '{}', when nothing matches.
    -- Returning an empty array instead keeps the Dart side free of null checks.
    coalesce(array_agg(e.user_id) filter (where e.free_hours >= p_min_free_hours), '{}'),
    coalesce(array_agg(e.user_id) filter (where e.free_hours <  p_min_free_hours), '{}'),
    extract(isodow from e.day) >= 6                              as is_weekend,
    exists (
      select 1 from holidays h
      where h.date = e.day and h.country = 'CZ'
    )                                                            as is_holiday
  from evaluated e
  group by e.day
  order by free_count desc, e.day;
$$;

comment on function group_free_days is
  'Per-date group availability. Security definer because busy_intervals is '
  'unreadable by any user: callers get counts and user ids, never intervals.';

-- Convenience wrapper for the Dates tab: the best N candidate dates.
-- M5 extends this with the weather score and the full ranking formula.
create or replace function top_free_days(p_trip uuid, p_limit int default 5)
returns table (
  day date, free_count int, total_count int,
  free_user_ids uuid[], busy_user_ids uuid[],
  is_weekend boolean, is_holiday boolean, score numeric
)
language sql security definer set search_path = public stable as $$
  select g.*,
         -- Partial ranking. Weather (0.20) and daylight (0.10) are added in
         -- M6 once the scoring engine exists; weights stay in sync with
         -- architecture section 11.3.
         round(
           0.45 * (g.free_count::numeric / nullif(g.total_count, 0))
         + 0.15 * (case when g.is_weekend then 1 else 0 end)
         + 0.10 * (case when g.is_holiday then 1 else 0 end)
         , 4) as score
  from group_free_days(p_trip) g
  where g.free_count >= greatest(2, ceil(g.total_count * 0.6))
  order by score desc, g.day
  limit p_limit;
$$;

grant execute on function group_free_days(uuid, numeric, time, time) to authenticated;
grant execute on function top_free_days(uuid, int) to authenticated;
