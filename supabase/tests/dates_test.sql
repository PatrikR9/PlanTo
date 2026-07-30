-- M5 + granularity: manual availability, the two solver modes, voting,
-- locking.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/dates_test.sql
--
-- What is worth testing is not the happy path. It is the timezone conversion,
-- the authorisation guards, the half-open ranges, multi-day feasibility, and
-- the run merging in slot mode — five things that all fail silently.

begin;
set local role postgres;

insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at,
                        created_at, updated_at)
values
  ('aaaa1111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'org@test.cz', now(), now(), now()),
  ('bbbb2222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'mem@test.cz', now(), now(), now()),
  ('cccc3333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'out@test.cz', now(), now(), now());

insert into profiles (id, display_name) values
  ('aaaa1111-1111-1111-1111-111111111111', 'Organizator'),
  ('bbbb2222-2222-2222-2222-222222222222', 'Clen'),
  ('cccc3333-3333-3333-3333-333333333333', 'Cizinec')
on conflict (id) do nothing;

-- Day-mode trip: 11-15 Sep, two days long.
insert into trips (id, created_by, title, origin_label, origin_point,
                   date_window, duration_days, timezone, granularity)
values (
  'dddd4444-4444-4444-4444-444444444444',
  'aaaa1111-1111-1111-1111-111111111111',
  'Day mode', 'Praha', st_point(14.42, 50.08)::geography,
  tstzrange('2026-09-11 00:00+02', '2026-09-15 00:00+02'), 2,
  'Europe/Prague', 'day'
);

-- Time-mode trip: one Friday, 09:00-17:00, a 90-minute activity on a
-- 30-minute grid.
insert into trips (id, created_by, title, origin_label, origin_point,
                   date_window, duration_days, timezone,
                   granularity, slot_minutes, slot_step_minutes,
                   day_start, day_end)
values (
  'eeee5555-5555-5555-5555-555555555555',
  'aaaa1111-1111-1111-1111-111111111111',
  'Time mode', 'Praha', st_point(14.42, 50.08)::geography,
  tstzrange('2026-09-11 00:00+02', '2026-09-11 23:59+02'), 1,
  'Europe/Prague', 'time', 90, 30, '09:00', '17:00'
);

insert into trip_participants (trip_id, user_id, role) values
  ('dddd4444-4444-4444-4444-444444444444',
   'aaaa1111-1111-1111-1111-111111111111', 'organiser'),
  ('dddd4444-4444-4444-4444-444444444444',
   'bbbb2222-2222-2222-2222-222222222222', 'member'),
  ('eeee5555-5555-5555-5555-555555555555',
   'aaaa1111-1111-1111-1111-111111111111', 'organiser'),
  ('eeee5555-5555-5555-5555-555555555555',
   'bbbb2222-2222-2222-2222-222222222222', 'member');

-- ---------------------------------------------------------------------------
-- Manual availability
-- ---------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"bbbb2222-2222-2222-2222-222222222222"}';

select set_manual_busy(
  'dddd4444-4444-4444-4444-444444444444',
  '[{"day":"2026-09-12"}]'::jsonb
);

do $$
declare r record; n int;
begin
  -- A whole-day block must cover the entire usable window in the TRIP's
  -- timezone. Converting in UTC would start it two hours late in summer and
  -- the day would still count as free.
  select * into r
  from group_free_days('dddd4444-4444-4444-4444-444444444444')
  where day = date '2026-09-12';
  assert r.free_count = 1,
    format('12 Sep: only the organiser should be free, got %s', r.free_count);

  select * into r
  from group_free_days('dddd4444-4444-4444-4444-444444444444')
  where day = date '2026-09-14';
  assert r.free_count = 2, '14 Sep was never marked, both should be free';

  select count(*) into n
  from my_busy_blocks('dddd4444-4444-4444-4444-444444444444');
  assert n = 1, format('expected 1 block back, got %s', n);

  select is_all_day into r
  from my_busy_blocks('dddd4444-4444-4444-4444-444444444444');
  assert r.is_all_day, 'a block with no from/to is a whole day';

  select calendar_shared into r
  from trip_participants
  where trip_id = 'dddd4444-4444-4444-4444-444444444444'
    and user_id = 'bbbb2222-2222-2222-2222-222222222222';
  assert r.calendar_shared, 'saving must mark the person as having answered';

  raise notice 'manual availability: OK';
end $$;

-- Part of a day, and replace-not-append.
select set_manual_busy(
  'eeee5555-5555-5555-5555-555555555555',
  '[{"day":"2026-09-11","from":"10:00","to":"12:00"}]'::jsonb
);

do $$
declare r record; n int;
begin
  select count(*) into n
  from my_busy_blocks('eeee5555-5555-5555-5555-555555555555');
  assert n = 1, format('expected 1 partial block, got %s', n);

  select * into r from my_busy_blocks('eeee5555-5555-5555-5555-555555555555');
  assert not r.is_all_day, 'a block with from/to is not a whole day';
  assert r.from_time = time '10:00' and r.to_time = time '12:00',
    format('round-tripped as %s-%s', r.from_time, r.to_time);

  raise notice 'partial-day blocks: OK';
end $$;

-- Non-members write nothing.
set local request.jwt.claims = '{"sub":"cccc3333-3333-3333-3333-333333333333"}';
do $$
begin
  begin
    perform set_manual_busy('dddd4444-4444-4444-4444-444444444444',
                            '[{"day":"2026-09-12"}]'::jsonb);
    assert false, 'a non-member wrote availability into someone else''s trip';
  exception when insufficient_privilege then
    raise notice 'manual membership guard: OK';
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Day mode: multi-day feasibility
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"aaaa1111-1111-1111-1111-111111111111"}';
do $$
declare r record; n int;
begin
  select count(*) into n
  from trip_candidates('dddd4444-4444-4444-4444-444444444444', 50);
  -- Window 11-15 Sep, 2 days long: start days 11, 12, 13 and 14 fit.
  assert n = 4, format('expected 4 two-day blocks, got %s', n);

  -- A block is only feasible if EVERY day works. Starting on the 11th drags
  -- in the 12th, which the member cannot do — evaluating only the first day
  -- is the bug this guards.
  select * into r
  from trip_candidates('dddd4444-4444-4444-4444-444444444444', 50)
  where starts_at = ('2026-09-11'::timestamp) at time zone 'Europe/Prague';
  assert r.free_count = 1,
    format('11 Sep block spans the 12th, expected 1 free, got %s', r.free_count);
  assert r.ends_at = ('2026-09-13'::timestamp) at time zone 'Europe/Prague',
    'a 2-day block starting on the 11th ends (exclusive) on the 13th';

  select * into r
  from trip_candidates('dddd4444-4444-4444-4444-444444444444', 50)
  where starts_at = ('2026-09-13'::timestamp) at time zone 'Europe/Prague';
  assert r.free_count = 2, '13-14 Sep works for everyone';

  raise notice 'day mode multi-day feasibility: OK';
end $$;

-- ---------------------------------------------------------------------------
-- Time mode: slot generation and run merging
-- ---------------------------------------------------------------------------
do $$
declare r record; n int;
begin
  -- 09:00-17:00 with a 90-minute activity gives starts 09:00..15:30 on a
  -- 30-minute grid: 14 slots. The member is busy 10:00-12:00, so the free set
  -- changes exactly once, at 12:00 — two candidates, not fourteen. This is
  -- the merge that makes the screen readable.
  select count(*) into n
  from trip_candidates('eeee5555-5555-5555-5555-555555555555', 50);
  assert n = 2, format('expected 2 merged candidates, got %s', n);

  select * into r
  from trip_candidates('eeee5555-5555-5555-5555-555555555555', 50)
  where starts_at = ('2026-09-11 12:00'::timestamp) at time zone 'Europe/Prague';
  assert r.free_count = 2, 'everyone is free from 12:00';
  assert r.ends_at =
    ('2026-09-11 13:30'::timestamp) at time zone 'Europe/Prague',
    'a 90-minute activity from 12:00 ends at 13:30';
  -- The last slot of the run starts at 15:30 and runs to 17:00, so that is
  -- how much room the group actually has.
  assert r.window_ends_at =
    ('2026-09-11 17:00'::timestamp) at time zone 'Europe/Prague',
    format('free window should reach 17:00, got %s', r.window_ends_at);

  select * into r
  from trip_candidates('eeee5555-5555-5555-5555-555555555555', 50)
  where starts_at = ('2026-09-11 09:00'::timestamp) at time zone 'Europe/Prague';
  assert r.free_count = 1, 'the member is busy 10:00-12:00';
  -- Last slot of that run starts 11:30 (it still overlaps the busy block).
  assert r.window_ends_at =
    ('2026-09-11 13:00'::timestamp) at time zone 'Europe/Prague',
    format('first run should end at 13:00, got %s', r.window_ends_at);

  -- Nothing may be proposed that runs past the end of the usable day.
  select count(*) into n
  from trip_candidates('eeee5555-5555-5555-5555-555555555555', 50)
  where ends_at > ('2026-09-11 17:00'::timestamp) at time zone 'Europe/Prague';
  assert n = 0, 'a candidate spilled past day_end';

  -- Best first: 2 of 2 free beats 1 of 2.
  select starts_at into r
  from trip_candidates('eeee5555-5555-5555-5555-555555555555', 50) limit 1;
  assert r.starts_at =
    ('2026-09-11 12:00'::timestamp) at time zone 'Europe/Prague',
    'the fully free slot must rank first';

  raise notice 'time mode slots and merging: OK';
end $$;

-- ---------------------------------------------------------------------------
-- Voting
-- ---------------------------------------------------------------------------
select cast_slot_vote('eeee5555-5555-5555-5555-555555555555',
  ('2026-09-11 12:00'::timestamp) at time zone 'Europe/Prague', 'yes');

set local request.jwt.claims = '{"sub":"bbbb2222-2222-2222-2222-222222222222"}';
select cast_slot_vote('eeee5555-5555-5555-5555-555555555555',
  ('2026-09-11 12:00'::timestamp) at time zone 'Europe/Prague', 'maybe');

do $$
declare r record;
begin
  select * into r
  from trip_candidates('eeee5555-5555-5555-5555-555555555555', 50)
  where starts_at = ('2026-09-11 12:00'::timestamp) at time zone 'Europe/Prague';
  assert r.yes_count = 1 and r.maybe_count = 1 and r.no_count = 0,
    format('tally wrong: %s/%s/%s', r.yes_count, r.maybe_count, r.no_count);
  assert r.my_vote = 'maybe', format('own vote should be maybe, got %s', r.my_vote);
  raise notice 'voting: OK';
end $$;

-- Changing your mind overwrites; passing null withdraws.
select cast_slot_vote('eeee5555-5555-5555-5555-555555555555',
  ('2026-09-11 12:00'::timestamp) at time zone 'Europe/Prague', 'no');
select cast_slot_vote('eeee5555-5555-5555-5555-555555555555',
  ('2026-09-11 12:00'::timestamp) at time zone 'Europe/Prague', null);

do $$
declare r record;
begin
  select * into r
  from trip_candidates('eeee5555-5555-5555-5555-555555555555', 50)
  where starts_at = ('2026-09-11 12:00'::timestamp) at time zone 'Europe/Prague';
  assert r.no_count = 0 and r.maybe_count = 0 and r.my_vote is null,
    'change-then-withdraw left a vote behind';
  assert r.yes_count = 1, 'withdrawing must not touch anyone else''s vote';
  raise notice 'vote change and withdraw: OK';
end $$;

-- Non-members see nothing.
set local request.jwt.claims = '{"sub":"cccc3333-3333-3333-3333-333333333333"}';
do $$
declare n int;
begin
  select count(*) into n
  from trip_candidates('eeee5555-5555-5555-5555-555555555555', 50);
  assert n = 0, format('non-member leaked %s candidate rows', n);
  raise notice 'candidates membership guard: OK';
end $$;

-- ---------------------------------------------------------------------------
-- Locking
-- ---------------------------------------------------------------------------
-- A member is not an organiser. This is the guard that stops one person in a
-- group of six deciding for everyone.
set local request.jwt.claims = '{"sub":"bbbb2222-2222-2222-2222-222222222222"}';
do $$
begin
  begin
    perform lock_trip_slot('eeee5555-5555-5555-5555-555555555555',
      ('2026-09-11 12:00'::timestamp) at time zone 'Europe/Prague');
    assert false, 'a plain member locked the slot';
  exception when insufficient_privilege then
    raise notice 'lock organiser guard: OK';
  end;
end $$;

set local request.jwt.claims = '{"sub":"aaaa1111-1111-1111-1111-111111111111"}';
select lock_trip_slot('eeee5555-5555-5555-5555-555555555555',
  ('2026-09-11 12:00'::timestamp) at time zone 'Europe/Prague');

do $$
declare r record; v_range tstzrange; v_status trip_status;
begin
  select locked_range, status into v_range, v_status
  from trips where id = 'eeee5555-5555-5555-5555-555555555555';
  assert lower(v_range) =
    ('2026-09-11 12:00'::timestamp) at time zone 'Europe/Prague',
    'locked start is wrong';
  assert upper(v_range) =
    ('2026-09-11 13:30'::timestamp) at time zone 'Europe/Prague',
    format('a 90-minute activity from 12:00 ends at 13:30, got %s', upper(v_range));
  assert v_status = 'date_locked', 'status must move to date_locked';

  -- Once decided, the screen is about the decision: the locked slot sorts
  -- first whatever it scores.
  select * into r
  from trip_candidates('eeee5555-5555-5555-5555-555555555555', 50) limit 1;
  assert r.is_locked, 'the locked slot must be listed first and flagged';

  raise notice 'locking: OK';
end $$;

-- Day mode locks a whole block, and the range stays half-open.
select lock_trip_slot('dddd4444-4444-4444-4444-444444444444',
  ('2026-09-13'::timestamp) at time zone 'Europe/Prague');
do $$
declare v_range tstzrange;
begin
  select locked_range into v_range
  from trips where id = 'dddd4444-4444-4444-4444-444444444444';
  assert upper(v_range) = ('2026-09-15'::timestamp) at time zone 'Europe/Prague',
    format('a 2-day trip from the 13th ends (exclusive) on the 15th, got %s',
           upper(v_range));
  raise notice 'day mode locking: OK';
end $$;

-- Outside the window is a client bug, refused here too.
do $$
begin
  begin
    perform lock_trip_slot('dddd4444-4444-4444-4444-444444444444',
      ('2026-12-24'::timestamp) at time zone 'Europe/Prague');
    assert false, 'locked a slot outside the trip window';
  exception when data_exception then
    raise notice 'lock window guard: OK';
  end;
end $$;

select unlock_trip_slot('dddd4444-4444-4444-4444-444444444444');
do $$
declare v_status trip_status; v_range tstzrange;
begin
  select status, locked_range into v_status, v_range
  from trips where id = 'dddd4444-4444-4444-4444-444444444444';
  assert v_range is null and v_status = 'planning', 'unlock failed';
  raise notice 'unlock: OK';
end $$;

rollback;
