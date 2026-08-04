-- ============================================================================
-- M7, first half — where you are going, and roughly how you get there.
--
-- READ THIS BEFORE ASSUMING IT DOES MORE THAN IT DOES.
--
-- These are ESTIMATES, computed from geometry and a fare model. There is no
-- timetable behind them and no departure time, because a real itinerary needs
-- a routing engine and the only free one for CZ/SK/AT/DE/PL is Transitous,
-- which is a community service with no commercial licence (cost register
-- C1). MOTIS gets self-hosted on the VPS at first revenue; the shape of
-- transport_options() is the shape MOTIS will fill, so that swap changes this
-- file and nothing above it.
--
-- Until then the honest product is "≈ 2 h 10 min, ≈ 240–320 Kč, odhad" plus a
-- link into IDOS, which is where a Czech person was going to check anyway.
-- Architecture section 1.6: honest confidence beats false precision.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. A destination you can route to
-- ---------------------------------------------------------------------------
-- destination_free already held a name. A name is not a place, so nothing
-- could be measured from it.
alter table trips
  add column if not exists destination_point geography(point, 4326);

comment on column trips.destination_point is
  'Coordinates for destination_free. Set from the same hard-coded city list '
  'the origin uses — there is no geocoder until MOTIS brings one.';

-- ---------------------------------------------------------------------------
-- 2. Cost inputs, in one place
-- ---------------------------------------------------------------------------
-- In app_config rather than baked into the function so a fuel price can be
-- corrected without a migration. They are national averages, and they are
-- labelled as such wherever the number is shown.
insert into app_config (key, value) values
  ('fuel_price_czk_per_l',   '38.5'::jsonb),
  ('car_consumption_l_100',  '6.8'::jsonb),
  ('rail_czk_per_km',        '2.1'::jsonb),
  ('bus_czk_per_km',         '1.6'::jsonb)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 3. The estimator
-- ---------------------------------------------------------------------------
-- Straight-line distance is not road distance. The multipliers below are the
-- honest part of the model: 1.25 for road, 1.20 for rail, both derived from
-- how Czech roads and lines actually wander round the terrain. Average speeds
-- are by distance band, because a 20 km hop is all junctions and a 200 km run
-- is all motorway.
create or replace function transport_options(p_trip uuid)
returns table (
  mode            text,
  distance_km     numeric,
  duration_min    int,
  cost_min_czk    numeric,
  cost_max_czk    numeric,
  per_person      boolean,
  confidence      text
)
language plpgsql
security definer
set search_path = public
stable
as $$
#variable_conflict use_column
declare
  t         trips%rowtype;
  v_crow_km numeric;
  v_people  int;
  v_fuel    numeric;
  v_cons    numeric;
  v_rail    numeric;
  v_bus     numeric;
begin
  select * into t from trips where id = p_trip;
  if not found or not is_trip_member(p_trip) then
    return;                       -- a non-member gets no rows, not an error
  end if;

  -- No destination yet is the normal state of a trip being planned, and it
  -- is not an error. The screen says "pick somewhere" rather than showing a
  -- route to nowhere.
  if t.destination_point is null then
    return;
  end if;

  v_crow_km := st_distance(t.origin_point, t.destination_point) / 1000.0;

  select greatest(1, count(*))::int into v_people
  from trip_participants p
  where p.trip_id = p_trip and p.status <> 'declined';

  select (value #>> '{}')::numeric into v_fuel
  from app_config where key = 'fuel_price_czk_per_l';
  select (value #>> '{}')::numeric into v_cons
  from app_config where key = 'car_consumption_l_100';
  select (value #>> '{}')::numeric into v_rail
  from app_config where key = 'rail_czk_per_km';
  select (value #>> '{}')::numeric into v_bus
  from app_config where key = 'bus_czk_per_km';

  -- ---- car --------------------------------------------------------------
  -- Fuel is the only cost modelled. Tolls are deliberately absent: the Czech
  -- motorway vignette is annual, so a per-trip share of it is a number the
  -- driver would not recognise. Parking arrives with the destinations table.
  if t.transport in ('car', 'either') then
    return query
    with d as (select v_crow_km * 1.25 as km)
    select
      'car'::text,
      round(d.km, 1),
      -- Door to door, so a flat 10 minutes for getting out and parking.
      (10 + (d.km / case
                      when d.km < 30  then 45
                      when d.km < 100 then 70
                      else 85
                    end) * 60)::int,
      -- Split across the car. Two people in a car is the cheapest way to
      -- travel in Czechia and the model has to show that.
      round(d.km * 2 * v_cons / 100 * v_fuel / least(v_people, 5) * 0.85, 0),
      round(d.km * 2 * v_cons / 100 * v_fuel / least(v_people, 5) * 1.15, 0),
      false,
      'estimate'::text
    from d;
  end if;

  -- ---- public transport --------------------------------------------------
  -- One row, not "train" and "bus" separately: without a timetable we cannot
  -- say which one runs, and inventing a choice would be the false precision
  -- the product principles rule out.
  if t.transport in ('public', 'either') then
    return query
    with d as (select v_crow_km * 1.20 as km)
    select
      'public'::text,
      round(d.km, 1),
      -- Slower than the car under 30 km (waiting, transfers) and comparable
      -- above it. The +15 is getting to the station and the connection you
      -- just missed.
      (15 + (d.km / case
                      when d.km < 30  then 28
                      when d.km < 100 then 55
                      else 75
                    end) * 60)::int,
      -- Return fare, per person, on the cheaper of rail and coach. The band
      -- is wide on purpose: it spans a discounted advance ticket and a full
      -- fare bought on the day.
      round(greatest(30, d.km * 2 * least(v_rail, v_bus) * 0.7), 0),
      round(greatest(60, d.km * 2 * greatest(v_rail, v_bus) * 1.2), 0),
      true,
      'estimate'::text
    from d;
  end if;
end;
$$;

comment on function transport_options is
  'Deterministic distance/time/cost estimates. No timetable: real departures '
  'arrive with a self-hosted MOTIS. Every number is an estimate and must be '
  'labelled as one in the UI.';

grant execute on function transport_options(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Setting a destination
-- ---------------------------------------------------------------------------
-- An RPC rather than a plain update because destination_point is geography:
-- over PostgREST that means the client sending EWKT and relying on an
-- implicit cast, which is exactly the fragility create_trip avoids.
create or replace function set_trip_destination(
  p_trip  uuid,
  p_label text,
  p_lat   double precision,
  p_lon   double precision
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_trip_organiser(p_trip) then
    raise exception 'only the organiser can set the destination'
      using errcode = '42501';
  end if;

  -- destination_id is cleared, not left alone. A trip carrying both a curated
  -- destination and a free one has two answers to "where is this going", and
  -- nothing in the schema says which wins — so the weather function would
  -- read one and the transport estimate the other, and they would disagree
  -- without either being wrong. One destination at a time.
  update trips
     set destination_id    = null,
         destination_free  = p_label,
         destination_point = case
           when p_lat is null or p_lon is null then null
           else st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography
         end
   where id = p_trip;
end;
$$;

grant execute on function set_trip_destination(
  uuid, text, double precision, double precision
) to authenticated;

-- ---------------------------------------------------------------------------
-- 4b. The forecast has to follow the destination too
-- ---------------------------------------------------------------------------
-- _trip_weather_point was written when the only destination a trip could have
-- was a row in `destinations`, so it reads destinations.point and otherwise
-- falls back to the origin. This migration introduced a second way to have a
-- destination, and without this the two disagree in the worst possible
-- direction: the Plan tab measures the distance to Špindlerův Mlýn while the
-- Dates tab scores the weather in Prague, and both look right.
--
-- Same return type, so CREATE OR REPLACE is enough (trap 8 only bites when
-- the columns change).
create or replace function _trip_weather_point(p_trip uuid)
returns table (lat numeric, lon numeric)
language sql
security definer
set search_path = public
stable
as $$
  select round(st_y(coalesce(d.point, t.destination_point,
                             t.origin_point)::geometry)::numeric, 1),
         round(st_x(coalesce(d.point, t.destination_point,
                             t.origin_point)::geometry)::numeric, 1)
  from trips t
  left join destinations d on d.id = t.destination_id
  where t.id = p_trip and is_trip_member(p_trip);
$$;

revoke execute on function _trip_weather_point(uuid) from public;

-- ---------------------------------------------------------------------------
-- 5. Read model
-- ---------------------------------------------------------------------------
-- Recreated rather than replaced: the view gains two columns in the middle of
-- its natural order, and CREATE OR REPLACE VIEW only allows additions at the
-- end. (Trap 8 in the register — it costs one line to avoid and an afternoon
-- to diagnose.)
drop view if exists trips_list;

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
  st_y(t.destination_point::geometry) as destination_lat,
  st_x(t.destination_point::geometry) as destination_lon,
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
