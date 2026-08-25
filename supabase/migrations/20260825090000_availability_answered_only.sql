-- ============================================================================
-- Do dostupnosti se počítají jenom lidi, kteří ji zadali.
--
-- CHYBA, KTEROU TO OPRAVUJE
--
-- `participants` bral každého, kdo neodmítl, a `busy_intervals` se připojoval
-- přes LEFT JOIN. Kdo nikdy nesdílel, neměl žádný obsazený interval — a
-- prázdný rozsah znamená „volný v každém slotu". Obrazovka pak současně
-- tvrdila **„5/5 volných"** a **„čekáme ještě na 4 lidi"**.
--
-- Nebyla to chyba zobrazení. Solver odpovídal na otázku „kdo může" číslem,
-- které z poloviny vzniklo z ticha, a na tom čísle skupina zamyká termín.
-- U produktu, jehož jediný slib je „najdi termín, který všem vyjde", je to
-- nejdražší možná chyba: vypadá jako správná odpověď.
--
-- ROZHODNUTÍ
--
-- Počítají se jen ti, kdo dostupnost zadali (`calendar_shared`). Kdo ji
-- nezadal, není v žádném čísle — ani jako volný, ani jako chybějící. „5/5"
-- teď znamená pět lidí, o kterých něco víme, a ne pět lidí, z nichž čtyři
-- mlčí.
--
-- Skóre dělí `nullif(p_total, 0)`, takže nula odpovědí dá NULL, ne pád.
-- Obrazovka má na „zatím nikdo nesdílel" vlastní stav (`canProposeDates`).
--
-- `create or replace` zachovává granty, takže se znovu neudělují.
--
-- Apply with: supabase db push
-- ============================================================================

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
      and tp.calendar_shared
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
        and tp.calendar_shared
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
