-- Correctness test for the availability solver.
-- Two ways to run it:
--   1. psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/availability_test.sql
--   2. Paste the whole file into the Supabase SQL Editor (it runs as postgres).
--      It ends in ROLLBACK, so it never leaves fixture data behind.
--
-- The solver is one of the four things worth near-total test coverage
-- (architecture section 15.5): a bug here produces a wrong plan, silently.

begin;
set local role postgres;

-- fixture: 3 users, a 5-day date_window, one busy Saturday
-- auth.users is managed by GoTrue; these are the columns it needs to accept a
-- hand-made row. If your Supabase version complains about another NOT NULL,
-- add it here rather than weakening the test.
insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at,
                        created_at, updated_at)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'a@test.cz', now(), now(), now()),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'b@test.cz', now(), now(), now()),
  ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'c@test.cz', now(), now(), now());

-- `on conflict` kvůli triggeru `on_auth_user_created`: vložení do
-- auth.users už profil založilo, takže tenhle insert do něj jen
-- doplní jméno. Bez toho test spadne na profiles_pkey dřív, než se
-- vůbec dostane k tomu, co má ověřit.
insert into profiles (id, display_name, gender) values
  ('11111111-1111-1111-1111-111111111111', 'Anna',  'f'),
  ('22222222-2222-2222-2222-222222222222', 'Bohus', 'm'),
  ('33333333-3333-3333-3333-333333333333', 'Cyril', 'm')
on conflict (id) do update set display_name = excluded.display_name, gender = excluded.gender;

insert into trips (id, created_by, title, origin_label, origin_point, date_window, duration_days)
values (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '11111111-1111-1111-1111-111111111111',
  'Test', 'Praha', st_point(14.42, 50.08)::geography,
  tstzrange('2026-09-11 00:00+02', '2026-09-15 00:00+02'), 1
);

insert into trip_participants (trip_id, user_id, role) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'organiser'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '22222222-2222-2222-2222-222222222222', 'member'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '33333333-3333-3333-3333-333333333333', 'member');

-- Bohus works all day Saturday 12 Sep
insert into busy_intervals (trip_id, user_id, period) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '22222222-2222-2222-2222-222222222222',
   tstzrange('2026-09-12 08:00+02', '2026-09-12 20:00+02'));

-- Cyril has dinner Saturday evening — OUTSIDE the usable day date_window, so it
-- must NOT disqualify him. This is the case a naive overlap check gets wrong.
insert into busy_intervals (trip_id, user_id, period) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '33333333-3333-3333-3333-333333333333',
   tstzrange('2026-09-12 21:30+02', '2026-09-12 23:30+02'));

-- Impersonate Anna so the membership guard is exercised for real.
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare r record;
begin
  select * into r
  from group_free_days('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  where day = date '2026-09-12';

  assert r.free_count = 2,
    format('Saturday should have 2 free (Bohus busy), got %s', r.free_count);
  assert r.total_count = 3, 'total should be 3';
  assert '33333333-3333-3333-3333-333333333333' = any(r.free_user_ids),
    'an evening event must not disqualify a day';
  assert r.is_weekend, '12 Sep 2026 is a Saturday';

  select * into r
  from group_free_days('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  where day = date '2026-09-13';
  assert r.free_count = 3, 'Sunday should have everyone free';

  raise notice 'availability solver: OK';
end $$;

-- Non-member must get nothing back, not an error and not data.
set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999"}';
do $$
declare n int;
begin
  select count(*) into n
  from group_free_days('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  assert n = 0, format('non-member leaked %s rows', n);
  raise notice 'membership guard: OK';
end $$;

rollback;
