-- ============================================================================
-- M5 — dates: manual availability, voting, and locking a date.
--
-- Two features that belong in one migration because they are two halves of
-- the same flow: you cannot vote on candidate dates until everyone's
-- availability is in, and on a device where the calendar plugin is missing or
-- the permission was refused, manual entry is the only way it gets there.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Where a busy interval came from
-- ---------------------------------------------------------------------------
-- The solver does not care, but the UI does: reopening the manual grid has to
-- show the days the user previously ticked, and it must not present intervals
-- derived from their calendar as if they had typed them in.
--
-- Manual and calendar are mutually exclusive per (trip, user). Both writers
-- replace the whole set, because the alternative — merging two sources — has
-- no correct answer when the calendar says free and the person says busy.
alter table busy_intervals
  add column if not exists source_kind text not null default 'calendar'
    check (source_kind in ('calendar', 'manual'));

comment on column busy_intervals.source_kind is
  'calendar = derived on device from CalendarProvider; manual = the user '
  'ticked days in the grid. Mutually exclusive per (trip_id, user_id).';

-- ---------------------------------------------------------------------------
-- 2. Manual availability
-- ---------------------------------------------------------------------------
-- Days rather than intervals. Somebody filling this in by hand knows "I can't
-- on the 12th"; asking them for 14:00-18:00 would be a worse answer more
-- slowly. A ticked day is stored as local midnight to local midnight in the
-- TRIP's timezone, which covers the whole usable window that group_free_days
-- evaluates, so the day drops to zero free hours.
--
-- The conversion happens here and not in Dart on purpose: the client has no
-- timezone database (adding one costs a dependency and ~900 kB of data),
-- Postgres already has one, and trips.timezone is the authoritative value.
-- Doing it on the device would also be wrong for anyone travelling.
create or replace function set_manual_busy_days(
  p_trip uuid,
  p_days date[]
)
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

  -- SECURITY: security definer bypasses RLS, so membership is checked here.
  -- Without this any authenticated user could write intervals into any trip.
  if not is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;

  select timezone, date_window into v_tz, v_win from trips where id = p_trip;

  -- Replace, never append: a second pass through the grid with a day
  -- unticked must remove it.
  delete from busy_intervals where trip_id = p_trip and user_id = v_user;

  insert into busy_intervals (trip_id, user_id, period, is_all_day, source_kind)
  select
    p_trip,
    v_user,
    tstzrange(
      (d::timestamp) at time zone v_tz,
      ((d + 1)::timestamp) at time zone v_tz,
      '[)'
    ),
    true,
    'manual'
  from unnest(coalesce(p_days, '{}'::date[])) as d
  -- Ignore anything outside the trip window. A stale client or a hand-crafted
  -- call should not be able to grow the table with rows the solver will never
  -- look at.
  where tstzrange(
          (d::timestamp) at time zone v_tz,
          ((d + 1)::timestamp) at time zone v_tz,
          '[)'
        ) && v_win;

  -- An empty selection is a real answer — "nothing blocks me" — and the most
  -- useful one there is. It must count as having shared, or the group waits
  -- forever on somebody who already answered.
  update trip_participants
     set calendar_shared = true
   where trip_id = p_trip and user_id = v_user;
end;
$$;

comment on function set_manual_busy_days is
  'Replaces the caller''s busy days for a trip from a list of dates, '
  'interpreted in the trip timezone. An empty list still marks them as having '
  'shared availability.';

-- Reading back what the user ticked.
--
-- Needed as a function because SELECT on busy_intervals is revoked from every
-- role: nobody reads the raw rows, not even their own, so that a future bug
-- in a SELECT policy cannot leak a group's schedule. This returns only the
-- caller's own manual days and nothing about anyone else.
create or replace function my_manual_busy_days(p_trip uuid)
returns setof date
language sql
security definer
set search_path = public
stable
as $$
  select distinct (lower(b.period) at time zone t.timezone)::date as day
  from busy_intervals b
  join trips t on t.id = b.trip_id
  where b.trip_id = p_trip
    and b.user_id = auth.uid()
    and b.source_kind = 'manual'
    and is_trip_member(p_trip)
  order by day;
$$;

-- ---------------------------------------------------------------------------
-- 3. Voting
-- ---------------------------------------------------------------------------
-- Three states, not two. "Maybe" is the honest answer to most proposed dates
-- and forcing it into yes/no is what makes group polls useless.
do $$ begin
  create type date_vote as enum ('yes', 'maybe', 'no');
exception when duplicate_object then null;
end $$;

create table if not exists date_votes (
  trip_id    uuid not null references trips on delete cascade,
  day        date not null,
  user_id    uuid not null references profiles on delete cascade,
  vote       date_vote not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (trip_id, day, user_id)
);
create index if not exists date_votes_trip_day_idx on date_votes (trip_id, day);

drop trigger if exists date_votes_updated on date_votes;
create trigger date_votes_updated before update on date_votes
  for each row execute function set_updated_at();

alter table date_votes enable row level security;

-- Votes are public within the trip: the point of voting is that the group can
-- see where it stands. This is the opposite of busy_intervals, deliberately.
drop policy if exists date_votes_read on date_votes;
create policy date_votes_read on date_votes
  for select using (is_trip_member(trip_id));

drop policy if exists date_votes_write_own on date_votes;
create policy date_votes_write_own on date_votes
  for all
  using (user_id = auth.uid() and is_trip_member(trip_id))
  with check (user_id = auth.uid() and is_trip_member(trip_id));

-- Cast or withdraw a vote. p_vote null withdraws.
create or replace function cast_date_vote(
  p_trip uuid,
  p_day  date,
  p_vote text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;

  if p_vote is null then
    delete from date_votes
     where trip_id = p_trip and day = p_day and user_id = v_user;
    return;
  end if;

  if p_vote not in ('yes', 'maybe', 'no') then
    raise exception 'invalid vote %', p_vote using errcode = '22000';
  end if;

  insert into date_votes (trip_id, day, user_id, vote)
  values (p_trip, p_day, v_user, p_vote::date_vote)
  on conflict (trip_id, day, user_id)
  do update set vote = excluded.vote, updated_at = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Candidate dates for the Dates tab
-- ---------------------------------------------------------------------------
-- Supersedes top_free_days(), which returned the same ranking without votes
-- and filtered out days below a quorum. The filter was wrong for the Dates
-- tab: a group of three where one person is free on exactly one day still
-- needs to see that day, with the reason it scores badly, rather than an
-- empty screen. Ranking lives in one place only.
drop function if exists top_free_days(uuid, int);

create or replace function date_candidates(
  p_trip  uuid,
  p_limit int default 10
)
returns table (
  day           date,
  free_count    int,
  total_count   int,
  free_user_ids uuid[],
  busy_user_ids uuid[],
  is_weekend    boolean,
  is_holiday    boolean,
  score         numeric,
  yes_count     int,
  maybe_count   int,
  no_count      int,
  my_vote       text,
  is_locked     boolean
)
language sql
security definer
set search_path = public
stable
as $$
  with locked as (
    select lower(t.locked_date) as locked_day
    from trips t
    where t.id = p_trip and is_trip_member(p_trip)
  ),
  -- group_free_days carries its own membership guard and returns zero rows to
  -- a non-member, which cascades through every join below.
  base as (
    select * from group_free_days(p_trip)
  ),
  tallied as (
    select
      g.*,
      -- Weather (0.20) and daylight (0.10) join this formula in M6. The
      -- weights are the ones in architecture section 11.3 and must stay in
      -- step with it.
      round(
          0.45 * (g.free_count::numeric / nullif(g.total_count, 0))
        + 0.15 * (case when g.is_weekend then 1 else 0 end)
        + 0.10 * (case when g.is_holiday then 1 else 0 end)
      , 4) as score,
      coalesce((select count(*) from date_votes v
                 where v.trip_id = p_trip and v.day = g.day
                   and v.vote = 'yes'), 0)::int   as yes_count,
      coalesce((select count(*) from date_votes v
                 where v.trip_id = p_trip and v.day = g.day
                   and v.vote = 'maybe'), 0)::int as maybe_count,
      coalesce((select count(*) from date_votes v
                 where v.trip_id = p_trip and v.day = g.day
                   and v.vote = 'no'), 0)::int    as no_count,
      (select v.vote::text from date_votes v
        where v.trip_id = p_trip and v.day = g.day
          and v.user_id = auth.uid())             as my_vote
    from base g
  )
  select
    t.day, t.free_count, t.total_count, t.free_user_ids, t.busy_user_ids,
    t.is_weekend, t.is_holiday, t.score,
    t.yes_count, t.maybe_count, t.no_count, t.my_vote,
    (l.locked_day is not null and l.locked_day = t.day) as is_locked
  from tallied t
  left join locked l on true
  -- A locked date is always first, whatever it scores: once the group has
  -- decided, the screen is about the decision, not about second-guessing it.
  order by (l.locked_day is not null and l.locked_day = t.day) desc,
           t.score desc,
           t.day
  limit p_limit;
$$;

comment on function date_candidates is
  'Ranked candidate dates with vote tallies and the caller''s own vote. '
  'Security definer; membership is enforced through group_free_days.';

-- ---------------------------------------------------------------------------
-- 5. Locking a date
-- ---------------------------------------------------------------------------
-- The organiser decides. Voting informs that decision, it does not replace
-- it — a poll that automatically wins on a plurality picks the date the two
-- loudest people answered first.
create or replace function lock_trip_date(p_trip uuid, p_day date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_duration int;
  v_win      tstzrange;
  v_tz       text;
begin
  if not is_trip_organiser(p_trip) then
    raise exception 'only the organiser can lock a date' using errcode = '42501';
  end if;

  select coalesce(duration_days, 1), date_window, timezone
    into v_duration, v_win, v_tz
  from trips where id = p_trip;

  if not (tstzrange(
            (p_day::timestamp) at time zone v_tz,
            ((p_day + 1)::timestamp) at time zone v_tz,
            '[)'
          ) && v_win) then
    raise exception 'date is outside the trip window' using errcode = '22000';
  end if;

  update trips
     set locked_date = daterange(p_day, p_day + v_duration, '[)'),
         status      = 'date_locked'
   where id = p_trip;
end;
$$;

create or replace function unlock_trip_date(p_trip uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_trip_organiser(p_trip) then
    raise exception 'only the organiser can unlock a date' using errcode = '42501';
  end if;

  update trips
     set locked_date = null,
         status      = 'planning'
   where id = p_trip;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Read model
-- ---------------------------------------------------------------------------
-- locked_date is a daterange, which PostgREST hands back as the literal
-- '[2026-09-12,2026-09-13)'. Parsing that in Dart is a string-manipulation
-- bug waiting to happen, so the view unpacks it the same way it already
-- unpacks date_window and origin_point.
--
-- CREATE OR REPLACE VIEW only permits new columns at the end, hence the
-- position.
create or replace view trips_list
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
  t.locked_date,
  t.destination_id,
  t.destination_free,
  t.created_by,
  t.created_at,
  (select count(*) from trip_participants p where p.trip_id = t.id)
    as participant_count,
  (select count(*) from trip_participants p
    where p.trip_id = t.id and p.calendar_shared) as calendar_shared_count,
  lower(t.locked_date) as locked_start,
  upper(t.locked_date) as locked_end,
  (select p.role from trip_participants p
    where p.trip_id = t.id and p.user_id = auth.uid()) as my_role
from trips t;

grant select on trips_list to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------
grant execute on function set_manual_busy_days(uuid, date[]) to authenticated;
grant execute on function my_manual_busy_days(uuid)          to authenticated;
grant execute on function cast_date_vote(uuid, date, text)   to authenticated;
grant execute on function date_candidates(uuid, int)         to authenticated;
grant execute on function lock_trip_date(uuid, date)         to authenticated;
grant execute on function unlock_trip_date(uuid)             to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Guardrail
-- ---------------------------------------------------------------------------
-- Same check as the RLS migration. It runs again here so that adding a table
-- in a later migration and forgetting RLS fails the push, not a code review.
do $$
declare
  unprotected text;
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
