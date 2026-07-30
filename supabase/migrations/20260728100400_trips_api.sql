-- ============================================================================
-- M2 — trip creation API.
--
-- Trips are created through an RPC rather than a plain PostgREST insert for
-- two reasons:
--   1. origin_point is `geography`. Over PostgREST that would mean the client
--      sending EWKT text and relying on an implicit cast — fragile, and it
--      pushes coordinate handling into Dart.
--   2. Creating a trip must also make the creator an organiser. Two inserts
--      from the client can half-succeed, leaving a trip nobody can edit.
--      One function, one transaction, no orphan state.
-- ============================================================================

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
  p_currency          char(3)  default 'CZK'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip uuid;
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- Anonymous users may join trips but not create them (architecture 10.4).
  if exists (select 1 from auth.users where id = v_user and is_anonymous) then
    raise exception 'anonymous users cannot create trips'
      using errcode = '42501';
  end if;

  if p_window_end <= p_window_start then
    raise exception 'window end must be after start' using errcode = '22000';
  end if;

  insert into trips (
    created_by, title, description, status,
    origin_label, origin_point, date_window,
    duration_days, transport, budget_per_person, currency,
    activity_tags, earliest_wake
  ) values (
    v_user, p_title, p_description, 'planning',
    p_origin_label,
    st_setsrid(st_makepoint(p_origin_lon, p_origin_lat), 4326)::geography,
    tstzrange(p_window_start, p_window_end, '[)'),
    p_duration_days, p_transport, p_budget_per_person, p_currency,
    p_activity_tags, p_earliest_wake
  )
  returning id into v_trip;

  insert into trip_participants (trip_id, user_id, role, status)
  values (v_trip, v_user, 'organiser', 'confirmed');

  return v_trip;
end;
$$;

grant execute on function create_trip(
  text, text, double precision, double precision, timestamptz, timestamptz,
  int, transport_pref, numeric, text[], text, time, char
) to authenticated;

-- Read model for the trips list.
--
-- A view rather than a client-side select because origin_point is geography:
-- PostgREST would hand back WKB hex and Dart would have to decode it. Here
-- the coordinates come back as plain numbers.
--
-- security_invoker makes the view respect the caller's RLS rather than the
-- view owner's — without it this would leak every trip in the database.
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
    where p.trip_id = t.id and p.calendar_shared) as calendar_shared_count
from trips t;

grant select on trips_list to authenticated;
