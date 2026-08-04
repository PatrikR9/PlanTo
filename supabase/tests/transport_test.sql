-- M7 transport estimates.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/transport_test.sql
--
-- These are estimates, so the exact numbers will get tuned and the test does
-- not pin them. What must not drift is the shape: no destination means no
-- rows rather than a route to nowhere, the transport preference is honoured,
-- a car is priced per car and a ticket per person, and sharing a car gets
-- cheaper as people get in.

begin;
set local role postgres;

insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at,
                        created_at, updated_at)
values
  ('c0c0c0c0-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'org@t.cz', now(), now(), now()),
  ('c0c0c0c0-0000-0000-0000-000000000002',
   '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'mem@t.cz', now(), now(), now());

insert into profiles (id, display_name) values
  ('c0c0c0c0-0000-0000-0000-000000000001', 'Org'),
  ('c0c0c0c0-0000-0000-0000-000000000002', 'Clen')
on conflict (id) do nothing;

-- Praha -> Český Krumlov, about 140 km by road.
insert into trips (id, created_by, title, origin_label, origin_point,
                   date_window, duration_days, transport)
values (
  'd0d0d0d0-0000-0000-0000-000000000001',
  'c0c0c0c0-0000-0000-0000-000000000001',
  'Doprava', 'Praha', st_point(14.4378, 50.0755)::geography,
  tstzrange('2026-09-11 00:00+02', '2026-09-15 00:00+02'), 2, 'either'
);

insert into trip_participants (trip_id, user_id, role) values
  ('d0d0d0d0-0000-0000-0000-000000000001',
   'c0c0c0c0-0000-0000-0000-000000000001', 'organiser');

set local role authenticated;
set local request.jwt.claims = '{"sub":"c0c0c0c0-0000-0000-0000-000000000001"}';

do $$
declare n int;
begin
  -- A trip with no destination is the normal state of one being planned. It
  -- must produce nothing, not a route to (0,0) in the Gulf of Guinea.
  select count(*) into n
  from transport_options('d0d0d0d0-0000-0000-0000-000000000001');
  assert n = 0, format('a destination-less trip produced %s options', n);
  raise notice 'no destination: OK';
end $$;

select set_trip_destination(
  'd0d0d0d0-0000-0000-0000-000000000001',
  'Český Krumlov', 48.8127, 14.3175
);

do $$
declare
  car    record;
  train  record;
  n      int;
begin
  select count(*) into n
  from transport_options('d0d0d0d0-0000-0000-0000-000000000001');
  assert n = 2, format('transport=either should offer both, got %s', n);

  select * into car
  from transport_options('d0d0d0d0-0000-0000-0000-000000000001')
  where mode = 'car';
  select * into train
  from transport_options('d0d0d0d0-0000-0000-0000-000000000001')
  where mode = 'public';

  -- Straight line is about 137 km; road adds a quarter.
  assert car.distance_km between 150 and 190,
    format('Praha-Krumlov by road should be ~170 km, got %s', car.distance_km);

  -- Two and a half to four hours is the believable band for that distance.
  assert car.duration_min between 100 and 250,
    format('car duration %s min is not believable', car.duration_min);
  assert train.duration_min > car.duration_min,
    'public transport should not beat a car to a small town';

  assert car.cost_min_czk < car.cost_max_czk, 'a range, not a point';
  assert not car.per_person, 'fuel is a cost per car, already divided';
  assert train.per_person, 'a ticket is a cost per person';

  raise notice 'estimates: OK';
end $$;

-- Sharing the car has to get cheaper as people get in. If it did not, the
-- model would be telling Czech students something they know to be false.
do $$
declare alone numeric; shared numeric;
begin
  select cost_min_czk into alone
  from transport_options('d0d0d0d0-0000-0000-0000-000000000001')
  where mode = 'car';

  set local role postgres;
  insert into trip_participants (trip_id, user_id, role)
  values ('d0d0d0d0-0000-0000-0000-000000000001',
          'c0c0c0c0-0000-0000-0000-000000000002', 'member');
  set local role authenticated;

  select cost_min_czk into shared
  from transport_options('d0d0d0d0-0000-0000-0000-000000000001')
  where mode = 'car';

  assert shared < alone,
    format('two in a car should cost less each: alone=%s shared=%s',
           alone, shared);
  raise notice 'car sharing: OK';
end $$;

-- The preference is not a suggestion.
set local role postgres;
update trips set transport = 'public'
where id = 'd0d0d0d0-0000-0000-0000-000000000001';
set local role authenticated;
set local request.jwt.claims = '{"sub":"c0c0c0c0-0000-0000-0000-000000000001"}';

do $$
declare n int;
begin
  select count(*) into n
  from transport_options('d0d0d0d0-0000-0000-0000-000000000001')
  where mode = 'car';
  assert n = 0, 'transport=public must not offer a car';
  raise notice 'transport preference: OK';
end $$;

-- Only the organiser decides where the group is going.
set local request.jwt.claims = '{"sub":"c0c0c0c0-0000-0000-0000-000000000002"}';
do $$
begin
  begin
    perform set_trip_destination(
      'd0d0d0d0-0000-0000-0000-000000000001', 'Vídeň', 48.2082, 16.3738);
    assert false, 'a plain member set the destination';
  exception when insufficient_privilege then
    raise notice 'destination organiser guard: OK';
  end;
end $$;

rollback;
