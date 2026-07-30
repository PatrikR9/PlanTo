-- ============================================================================
-- Planning granularity: whole days, or time slots.
--
-- The day solver answers "which date suits everyone". That is the right
-- question for a weekend in the mountains and the wrong one for "kino ve
-- čtvrtek" — for a two-hour thing the answer is a start time, not a date.
--
-- Rather than bolt a second feature on, this migration generalises the model:
-- a candidate is now a [starts_at, ends_at) range in both modes. A day-mode
-- candidate is simply a candidate whose range happens to be whole days. One
-- vote table, one lock, one ranking formula, one screen.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Trip configuration
-- ---------------------------------------------------------------------------
do $$ begin
  create type trip_granularity as enum ('day', 'time');
exception when duplicate_object then null;
end $$;

alter table trips
  add column if not exists granularity trip_granularity not null default 'day',
  -- How long the activity itself lasts, in minutes. Only meaningful in 'time'
  -- mode; null in day mode, where duration_days already says it.
  add column if not exists slot_minutes int
    check (slot_minutes is null or slot_minutes between 15 and 1440),
  -- How far apart proposed start times are. 15 lets you say "17:45", 60 keeps
  -- the list short. This is the knob people actually asked for.
  add column if not exists slot_step_minutes int not null default 30
    check (slot_step_minutes in (15, 30, 45, 60)),
  -- The usable part of a day. Previously hard-coded as function defaults,
  -- which was fine while everything was a day trip: a 19:00 board-game
  -- evening needs the window to reach 23:00, and a sunrise hike needs 05:00.
  add column if not exists day_start time not null default '07:00',
  add column if not exists day_end   time not null default '21:00',
  -- Replaces locked_date. A daterange cannot express "Thursday 19:00-21:30".
  add column if not exists locked_range tstzrange;

do $$ begin
  alter table trips add constraint trips_day_window_ordered
    check (day_end > day_start);
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table trips add constraint trips_slot_minutes_required
    check (granularity = 'day' or slot_minutes is not null);
exception when duplicate_object then null;
end $$;

-- trips_list selects locked_date, and Postgres refuses to drop a column a view
-- depends on. The view is rebuilt at the end of this file anyway.
drop view if exists trips_list;
alter table trips drop column if exists locked_date;

comment on column trips.granularity is
  'day = candidates are whole days (duration_days long); time = candidates '
  'are slot_minutes-long ranges on a slot_step_minutes grid.';

-- ---------------------------------------------------------------------------
-- 2. Votes move from a date to an instant
-- ---------------------------------------------------------------------------
-- Dropped and rebuilt rather than migrated in place: the table is one day old,
-- has never carried real data, and a backfill would only add a code path
-- nobody will ever execute again. In day mode slot_start is local midnight in
-- the trip's timezone, so the two modes share the key.
drop table if exists date_votes cascade;

create table date_votes (
  trip_id    uuid not null references trips on delete cascade,
  slot_start timestamptz not null,
  user_id    uuid not null references profiles on delete cascade,
  vote       date_vote not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (trip_id, slot_start, user_id)
);
-- Covers the tally aggregate below, which is the only read path.
create index date_votes_trip_slot_idx on date_votes (trip_id, slot_start);

create trigger date_votes_updated before update on date_votes
  for each row execute function set_updated_at();

alter table date_votes enable row level security;

create policy date_votes_read on date_votes
  for select using (is_trip_member(trip_id));

create policy date_votes_write_own on date_votes
  for all
  using (user_id = auth.uid() and is_trip_member(trip_id))
  with check (user_id = auth.uid() and is_trip_member(trip_id));

-- ---------------------------------------------------------------------------
-- 3. Day availability, now reading the trip's own usable window
-- ---------------------------------------------------------------------------
-- Same signature, so availability_test.sql and the heat strip keep working.
-- The defaults become null and mean "ask the trip", because 07:00-21:00 was
-- only ever a guess and is plainly wrong for an evening activity.
create or replace function group_free_days(
  p_trip           uuid,
  p_min_free_hours numeric default null,
  p_day_start      time default null,
  p_day_end        time default null
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
security definer
set search_path = public
stable
as $$
  with trip as (
    -- SECURITY: security definer bypasses RLS on busy_intervals, so the
    -- membership check has to be here. An empty CTE cascades to zero rows.
    select id, date_window, timezone,
           coalesce(p_day_start, day_start) as ds,
           coalesce(p_day_end,   day_end)   as de,
           granularity, slot_minutes
    from trips
    where id = p_trip and is_trip_member(id)
  ),
  cfg as (
    select trip.*,
           coalesce(
             p_min_free_hours,
             -- A whole-day trip wants a real day free; a two-hour activity
             -- only needs two hours. And never ask for more hours than the
             -- usable window contains, or every day scores zero.
             least(
               case when granularity = 'time'
                    then coalesce(slot_minutes, 120) / 60.0
                    else 6 end,
               extract(epoch from (de - ds)) / 3600.0
             )
           ) as min_hours
    from trip
  ),
  participants as (
    select tp.user_id
    from trip_participants tp
    join cfg on cfg.id = tp.trip_id
    where tp.status <> 'declined'
  ),
  days as (
    select generate_series(
             lower(cfg.date_window)::date,
             upper(cfg.date_window)::date,
             interval '1 day'
           )::date as day,
           cfg.timezone, cfg.ds, cfg.de, cfg.min_hours
    from cfg
  ),
  day_windows as (
    select days.day, days.min_hours,
           tstzrange(
             (days.day + days.ds) at time zone days.timezone,
             (days.day + days.de) at time zone days.timezone,
             '[)'
           ) as win
    from days
  ),
  -- One multirange per participant, built once. Everything after this is
  -- in-memory range algebra; this CTE is the only table access per user.
  busy_by_user as (
    select p.user_id,
           coalesce(range_agg(b.period), '{}'::tstzmultirange) as mr
    from participants p
    left join busy_intervals b
      on b.user_id = p.user_id and b.trip_id = p_trip
    group by p.user_id
  ),
  evaluated as (
    select dw.day, dw.min_hours, bu.user_id,
           multirange_hours(multirange(dw.win)) -
           multirange_hours(bu.mr * multirange(dw.win)) as free_hours
    from day_windows dw
    cross join busy_by_user bu
  )
  select
    e.day,
    count(*) filter (where e.free_hours >= e.min_hours)::int,
    count(*)::int,
    coalesce(array_agg(e.user_id) filter (where e.free_hours >= e.min_hours), '{}'),
    coalesce(array_agg(e.user_id) filter (where e.free_hours <  e.min_hours), '{}'),
    extract(isodow from e.day) >= 6,
    exists (select 1 from holidays h where h.date = e.day and h.country = 'CZ')
  from evaluated e
  group by e.day
  order by e.day;
$$;

-- ---------------------------------------------------------------------------
-- 3b. Shared helpers
-- ---------------------------------------------------------------------------
-- The ranking formula, in exactly one place. Weather (0.20) and daylight
-- (0.10) join it in M6; the weights are architecture section 11.3.
create or replace function _candidate_score(
  p_free int, p_total int, p_weekend boolean, p_holiday boolean
)
returns numeric language sql immutable as $$
  select round(
      0.45 * (p_free::numeric / nullif(p_total, 0))
    + 0.15 * (case when p_weekend then 1 else 0 end)
    + 0.10 * (case when p_holiday then 1 else 0 end)
  , 4);
$$;

-- One pass over the trip's votes instead of three correlated subqueries per
-- candidate. With 20 candidates that is 60 index probes turned into one scan.
create or replace function _vote_tally(p_trip uuid)
returns table (
  slot_start  timestamptz,
  yes_count   int,
  maybe_count int,
  no_count    int,
  my_vote     text
)
language sql
security definer
set search_path = public
stable
as $$
  select v.slot_start,
         count(*) filter (where v.vote = 'yes')::int,
         count(*) filter (where v.vote = 'maybe')::int,
         count(*) filter (where v.vote = 'no')::int,
         max(v.vote::text) filter (where v.user_id = auth.uid())
  from date_votes v
  where v.trip_id = p_trip
    -- Defence in depth. trip_candidates guards too, but a security definer
    -- helper that trusts its caller is exactly how these leak.
    and is_trip_member(p_trip)
  group by v.slot_start;
$$;

-- Internal. trip_candidates is security definer and owned by the same role,
-- so it can call these regardless; nobody else needs to.
revoke execute on function _vote_tally(uuid) from public;
revoke execute on function _candidate_score(int, int, boolean, boolean)
  from public;

-- ---------------------------------------------------------------------------
-- 4. The unified candidate solver
-- ---------------------------------------------------------------------------
-- plpgsql with an IF rather than one SQL statement with a UNION: the planner
-- would otherwise have to prepare the slot branch for every day-mode trip,
-- and that branch generates a row per (day x slot x participant).
--
-- Slot mode merges consecutive slots that have an identical free set into one
-- candidate (classic gaps-and-islands). Without it a 14-hour day at a 15
-- minute step produces 52 near-identical cards and the screen is unusable;
-- with it the group sees "Čt 6. 8., volno 14:00-18:30" once.
create or replace function trip_candidates(p_trip uuid, p_limit int default 20)
returns table (
  starts_at      timestamptz,
  ends_at        timestamptz,
  -- End of the contiguous free window the candidate sits in. Equals ends_at
  -- in day mode; in slot mode it is how much room there actually is, which is
  -- what tells a group they could start later if they wanted.
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
  is_locked      boolean
)
language plpgsql
security definer
set search_path = public
stable
as $$
#variable_conflict use_column
-- ^ RETURNS TABLE turns every output column into a plpgsql variable, and five
-- of them (free_count, is_weekend, score, …) are also column names in the
-- CTEs below. Everything here is alias-qualified, but this makes the
-- resolution rule explicit rather than relying on that discipline holding.
declare
  t          trips%rowtype;
  v_slot     interval;
  v_step     interval;
  v_duration int;
  v_last_day date;
  v_locked   timestamptz;
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
    )
    select
      (b.start_day::timestamp) at time zone t.timezone,
      ((b.start_day + v_duration)::timestamp) at time zone t.timezone,
      ((b.start_day + v_duration)::timestamp) at time zone t.timezone,
      b.free_count, b.total_count, b.free_ids, b.busy_ids,
      f.is_weekend, f.is_holiday,
      _candidate_score(b.free_count, b.total_count, f.is_weekend, f.is_holiday),
      coalesce(v.yes_count, 0), coalesce(v.maybe_count, 0),
      coalesce(v.no_count, 0), v.my_vote,
      v_locked is not null
        and v_locked = (b.start_day::timestamp) at time zone t.timezone
    from blocks b
    join free_days f on f.day = b.start_day
    left join _vote_tally(p_trip) v
      on v.slot_start = (b.start_day::timestamp) at time zone t.timezone
    order by
      (v_locked is not null
        and v_locked = (b.start_day::timestamp) at time zone t.timezone) desc,
      _candidate_score(b.free_count, b.total_count, f.is_weekend, f.is_holiday) desc,
      b.start_day
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
      -- A slot that starts before the window opens or ends after it closes is
      -- not a proposal, it is noise.
      where dw.win_end - v_slot >= dw.win_start
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
    )
    select
      m.starts_at,
      m.starts_at + v_slot,
      m.window_ends_at,
      m.free_count, m.total_count, m.free_ids, m.busy_ids,
      extract(isodow from m.day) >= 6,
      exists (select 1 from holidays h where h.date = m.day and h.country = 'CZ'),
      _candidate_score(
        m.free_count, m.total_count,
        extract(isodow from m.day) >= 6,
        exists (select 1 from holidays h
                 where h.date = m.day and h.country = 'CZ')
      ),
      coalesce(v.yes_count, 0), coalesce(v.maybe_count, 0),
      coalesce(v.no_count, 0), v.my_vote,
      v_locked is not null and v_locked = m.starts_at
    from merged m
    left join _vote_tally(p_trip) v on v.slot_start = m.starts_at
    order by
      (v_locked is not null and v_locked = m.starts_at) desc,
      _candidate_score(
        m.free_count, m.total_count,
        extract(isodow from m.day) >= 6,
        exists (select 1 from holidays h
                 where h.date = m.day and h.country = 'CZ')
      ) desc,
      m.starts_at
    limit p_limit;
  end if;
end;
$$;

comment on function trip_candidates is
  'Ranked candidates for either granularity, with vote tallies. Slot mode '
  'merges consecutive slots with an identical free set into one candidate.';

-- ---------------------------------------------------------------------------
-- 5. Locking
-- ---------------------------------------------------------------------------
create or replace function lock_trip_slot(p_trip uuid, p_start timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  t     trips%rowtype;
  v_end timestamptz;
begin
  if not is_trip_organiser(p_trip) then
    raise exception 'only the organiser can lock a date' using errcode = '42501';
  end if;

  select * into t from trips where id = p_trip;

  v_end := case
    when t.granularity = 'day'
      then p_start + make_interval(days => coalesce(t.duration_days, 1))
    else p_start + make_interval(mins => coalesce(t.slot_minutes, 120))
  end;

  if not (tstzrange(p_start, v_end, '[)') && t.date_window) then
    raise exception 'slot is outside the trip window' using errcode = '22000';
  end if;

  update trips
     set locked_range = tstzrange(p_start, v_end, '[)'),
         status       = 'date_locked'
   where id = p_trip;
end;
$$;

create or replace function unlock_trip_slot(p_trip uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_trip_organiser(p_trip) then
    raise exception 'only the organiser can unlock a date'
      using errcode = '42501';
  end if;

  update trips
     set locked_range = null, status = 'planning'
   where id = p_trip;
end;
$$;

drop function if exists lock_trip_date(uuid, date);
drop function if exists unlock_trip_date(uuid);
drop function if exists date_candidates(uuid, int);

-- ---------------------------------------------------------------------------
-- 6. Voting on an instant
-- ---------------------------------------------------------------------------
create or replace function cast_slot_vote(
  p_trip  uuid,
  p_start timestamptz,
  p_vote  text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;

  if p_vote is null then
    delete from date_votes
     where trip_id = p_trip and slot_start = p_start and user_id = v_user;
    return;
  end if;

  if p_vote not in ('yes', 'maybe', 'no') then
    raise exception 'invalid vote %', p_vote using errcode = '22000';
  end if;

  insert into date_votes (trip_id, slot_start, user_id, vote)
  values (p_trip, p_start, v_user, p_vote::date_vote)
  on conflict (trip_id, slot_start, user_id)
  do update set vote = excluded.vote, updated_at = now();
end;
$$;

drop function if exists cast_date_vote(uuid, date, text);

-- ---------------------------------------------------------------------------
-- 7. Manual availability, days and part-days
-- ---------------------------------------------------------------------------
-- Supersedes set_manual_busy_days. A time-mode trip needs "I can't on Tuesday
-- between 9 and 17", which a date[] cannot express. jsonb rather than a
-- composite type so the Dart side sends plain maps and no custom codec is
-- needed on either end.
--
-- Element shape:
--   {"day":"2026-08-04"}                          -> the whole day
--   {"day":"2026-08-04","from":"09:00","to":"17:00"} -> part of it
create or replace function set_manual_busy(p_trip uuid, p_blocks jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_tz   text;
  v_win  tstzrange;
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;

  select timezone, date_window into v_tz, v_win from trips where id = p_trip;

  -- Replace, never append. A second pass with a day unticked must remove it,
  -- and a calendar sync afterwards replaces the lot — the two sources are
  -- mutually exclusive because "calendar says free, person says busy" has no
  -- correct merge.
  delete from busy_intervals where trip_id = p_trip and user_id = v_user;

  insert into busy_intervals (trip_id, user_id, period, is_all_day, source_kind)
  select p_trip, v_user, r, (b ->> 'from') is null, 'manual'
  from jsonb_array_elements(coalesce(p_blocks, '[]'::jsonb)) as b
  cross join lateral (
    select tstzrange(
      (((b ->> 'day')::date + coalesce((b ->> 'from')::time, time '00:00'))
        ::timestamp) at time zone v_tz,
      (case
         when b ->> 'to' is null
           then (((b ->> 'day')::date + 1)::timestamp) at time zone v_tz
         else (((b ->> 'day')::date + (b ->> 'to')::time)::timestamp)
                at time zone v_tz
       end),
      '[)'
    ) as r
  ) x
  -- Reject anything empty or outside the window: a stale client must not be
  -- able to grow the table with rows the solver will never read.
  where not isempty(r) and r && v_win;

  update trip_participants
     set calendar_shared = true
   where trip_id = p_trip and user_id = v_user;
end;
$$;

drop function if exists set_manual_busy_days(uuid, date[]);

-- Reading back the caller's own blocks. SELECT on busy_intervals is revoked
-- from every role, including for your own rows, so this has to be a function.
--
-- Deliberately NOT filtered to source_kind = 'manual'. The editor is one
-- screen with two ways to fill it: import from the calendar, then adjust by
-- hand. Hiding the imported blocks would make the import look like it did
-- nothing, and saving afterwards would silently wipe it.
create or replace function my_busy_blocks(p_trip uuid)
returns table (day date, from_time time, to_time time, is_all_day boolean)
language sql
security definer
set search_path = public
stable
as $$
  select
    (lower(b.period) at time zone t.timezone)::date,
    (lower(b.period) at time zone t.timezone)::time,
    (upper(b.period) at time zone t.timezone)::time,
    b.is_all_day
  from busy_intervals b
  join trips t on t.id = b.trip_id
  where b.trip_id = p_trip
    and b.user_id = auth.uid()
    and is_trip_member(p_trip)
  order by 1, 2;
$$;

drop function if exists my_manual_busy_days(uuid);

-- ---------------------------------------------------------------------------
-- 9. Trip creation
-- ---------------------------------------------------------------------------
drop function if exists create_trip(
  text, text, double precision, double precision, timestamptz, timestamptz,
  int, transport_pref, numeric, text[], text, time, char
);

create or replace function create_trip(
  p_title             text,
  p_origin_label      text,
  p_origin_lat        double precision,
  p_origin_lon        double precision,
  p_window_start      timestamptz,
  p_window_end        timestamptz,
  p_duration_days     int      default 1,
  p_transport         transport_pref default 'either',
  p_budget_per_person numeric  default null,
  p_activity_tags     text[]   default '{}',
  p_description       text     default null,
  p_earliest_wake     time     default null,
  p_currency          char(3)  default 'CZK',
  p_granularity       text     default 'day',
  p_slot_minutes      int      default null,
  p_slot_step_minutes int      default 30,
  p_day_start         time     default '07:00',
  p_day_end           time     default '21:00'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip uuid;
  v_user uuid := auth.uid();
  v_days int;
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if exists (select 1 from auth.users where id = v_user and is_anonymous) then
    raise exception 'anonymous users cannot create trips' using errcode = '42501';
  end if;

  if p_window_end <= p_window_start then
    raise exception 'window end must be after start' using errcode = '22000';
  end if;

  if p_granularity not in ('day', 'time') then
    raise exception 'unknown granularity %', p_granularity using errcode = '22000';
  end if;

  v_days := (p_window_end::date - p_window_start::date) + 1;

  -- Guard rail, not a product limit. Time mode generates a row per
  -- (day x slot x participant); a 15-minute step over a year is 35 000 slots
  -- and a screen nobody can read. Six weeks is far more than anyone needs to
  -- schedule a two-hour thing.
  if p_granularity = 'time' and v_days > 42 then
    raise exception 'a time-based trip cannot span more than 6 weeks'
      using errcode = '22000';
  end if;

  if p_granularity = 'time'
     and (p_slot_minutes is null or p_slot_minutes < 15) then
    raise exception 'a time-based trip needs an activity length'
      using errcode = '22000';
  end if;

  insert into trips (
    created_by, title, description, status,
    origin_label, origin_point, date_window,
    duration_days, transport, budget_per_person, currency,
    activity_tags, earliest_wake,
    granularity, slot_minutes, slot_step_minutes, day_start, day_end
  ) values (
    v_user, p_title, p_description, 'planning',
    p_origin_label,
    st_setsrid(st_makepoint(p_origin_lon, p_origin_lat), 4326)::geography,
    tstzrange(p_window_start, p_window_end, '[)'),
    p_duration_days, p_transport, p_budget_per_person, p_currency,
    p_activity_tags, p_earliest_wake,
    p_granularity::trip_granularity,
    case when p_granularity = 'time' then p_slot_minutes end,
    p_slot_step_minutes, p_day_start, p_day_end
  )
  returning id into v_trip;

  insert into trip_participants (trip_id, user_id, role, status)
  values (v_trip, v_user, 'organiser', 'confirmed');

  return v_trip;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Read model
-- ---------------------------------------------------------------------------
-- Recreated rather than replaced: CREATE OR REPLACE VIEW cannot remove a
-- column, and locked_date is gone. Already dropped in section 1 so that the
-- ALTER TABLE could proceed.
create view trips_list
with (security_invoker = true)
as
select
  t.id,
  t.title,
  t.description,
  t.status,
  t.origin_label,
  st_y(t.origin_point::geometry) as origin_lat,
  st_x(t.origin_point::geometry) as origin_lon,
  lower(t.date_window)           as window_start,
  upper(t.date_window)           as window_end,
  t.duration_days,
  t.transport,
  t.budget_per_person,
  t.currency,
  t.activity_tags,
  t.earliest_wake,
  t.destination_id,
  t.destination_free,
  t.created_by,
  t.created_at,
  t.granularity,
  t.slot_minutes,
  t.slot_step_minutes,
  t.day_start,
  t.day_end,
  lower(t.locked_range) as locked_start,
  upper(t.locked_range) as locked_end,
  (select count(*) from trip_participants p where p.trip_id = t.id)
    as participant_count,
  (select count(*) from trip_participants p
    where p.trip_id = t.id and p.calendar_shared) as calendar_shared_count,
  (select p.role from trip_participants p
    where p.trip_id = t.id and p.user_id = auth.uid()) as my_role
from trips t;

grant select on trips_list to authenticated;

-- ---------------------------------------------------------------------------
-- 11. Grants
-- ---------------------------------------------------------------------------
grant execute on function trip_candidates(uuid, int)              to authenticated;
grant execute on function cast_slot_vote(uuid, timestamptz, text) to authenticated;
grant execute on function lock_trip_slot(uuid, timestamptz)       to authenticated;
grant execute on function unlock_trip_slot(uuid)                  to authenticated;
grant execute on function set_manual_busy(uuid, jsonb)            to authenticated;
grant execute on function my_busy_blocks(uuid)                    to authenticated;
grant execute on function group_free_days(uuid, numeric, time, time)
  to authenticated;
grant execute on function create_trip(
  text, text, double precision, double precision, timestamptz, timestamptz,
  int, transport_pref, numeric, text[], text, time, char,
  text, int, int, time, time
) to authenticated;

-- ---------------------------------------------------------------------------
-- 12. Guardrail
-- ---------------------------------------------------------------------------
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
