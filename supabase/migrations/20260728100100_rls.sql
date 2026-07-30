-- ============================================================================
-- Row Level Security — deny by default, everything resolves through two
-- membership helpers. Architecture section 9.7.
-- ============================================================================

create or replace function is_trip_member(p_trip uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from trip_participants
    where trip_id = p_trip and user_id = auth.uid()
  );
$$;

create or replace function is_trip_organiser(p_trip uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from trip_participants
    where trip_id = p_trip and user_id = auth.uid() and role = 'organiser'
  );
$$;

-- ---------------------------------------------------------------- profiles --
alter table profiles enable row level security;

create policy profiles_read_self on profiles
  for select using (id = auth.uid());

-- You can see the name and avatar of people you share a trip with, and
-- nothing else about them.
create policy profiles_read_covisible on profiles
  for select using (
    exists (
      select 1
      from trip_participants mine
      join trip_participants theirs on theirs.trip_id = mine.trip_id
      where mine.user_id = auth.uid() and theirs.user_id = profiles.id
    )
  );

create policy profiles_write_self on profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- plan / ai_preview_used are billing state: only the service role may set them.
--
-- A column-level REVOKE does NOT carve a hole out of a table-level grant, and
-- Supabase grants ALL on public tables to `authenticated` by default. So the
-- table-level UPDATE has to go first, then the allowed columns are granted
-- back explicitly. Without this a user could simply set their own plan to
-- 'pro' and every Pro gate in the app would open.
revoke update on profiles from authenticated;
grant update (
  display_name, gender, avatar_url, home_city, home_point, locale, currency
) on profiles to authenticated;

-- ------------------------------------------------------------------- trips --
alter table trips enable row level security;

create policy trips_read   on trips for select using (is_trip_member(id));
create policy trips_insert on trips for insert with check (created_by = auth.uid());
create policy trips_update on trips for update using (is_trip_organiser(id));
create policy trips_delete on trips for delete using (is_trip_organiser(id));

-- ------------------------------------------------------------ participants --
alter table trip_participants enable row level security;

create policy participants_read on trip_participants
  for select using (is_trip_member(trip_id));

-- Joining happens through the invite/redeem Edge Function (service role), so
-- there is deliberately no INSERT policy for authenticated users.
create policy participants_leave on trip_participants
  for delete using (user_id = auth.uid() or is_trip_organiser(trip_id));

create policy participants_update_self on trip_participants
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ----------------------------------------------------------------- invites --
alter table invites enable row level security;

-- Reading an invite row is an organiser action (link management). Redemption
-- never reads through RLS; it goes through the Edge Function.
create policy invites_manage on invites
  for all using (is_trip_organiser(trip_id)) with check (is_trip_organiser(trip_id));

-- --------------------------------------------------- calendar connections --
alter table calendar_connections enable row level security;

create policy calendars_own on calendar_connections
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------- busy intervals --
alter table busy_intervals enable row level security;

-- You may write only your own intervals …
create policy busy_write_own on busy_intervals
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- … and NOBODY reads the raw rows — not even other members of your own trip.
-- Group availability is exposed only through group_free_days(), which is
-- security definer and returns counts, never intervals. Defence in depth: a
-- future bug in a SELECT policy cannot leak when a session's schedule.
revoke select on busy_intervals from authenticated, anon;

-- ------------------------------------------------------------ destinations --
alter table destinations enable row level security;
create policy destinations_read on destinations for select using (true);
-- writes are service-role only (the monthly seeding job)

-- --------------------------------------------------- reference / config ----
alter table holidays enable row level security;
create policy holidays_read on holidays for select using (true);

alter table app_config enable row level security;
-- no policies: service role only, by design

-- ---------------------------------------------------------------- guardrail --
-- Fails the migration if a public table was added without RLS. This is the
-- check that stops a forgotten `alter table ... enable row level security`
-- from shipping (architecture section 13.2).
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
    -- Exclude tables owned by an extension. PostGIS puts spatial_ref_sys in
    -- public and we neither can nor should enable RLS on it: it is a public
    -- reference table of coordinate systems, owned by the extension, and
    -- ALTERing it breaks postgis upgrades.
    and c.oid not in (
      select d.objid
      from pg_depend d
      where d.deptype = 'e'
        and d.classid = 'pg_class'::regclass
    );

  if unprotected is not null then
    raise exception 'Tables without RLS: %', unprotected;
  end if;
end $$;
