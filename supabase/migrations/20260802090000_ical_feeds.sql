-- ============================================================================
-- Calendar by subscription link.
--
-- The browser has no calendar API, and the OAuth alternative is blocked on
-- three things we do not have: a verified domain, a Google OAuth client, and
-- Google's review of a sensitive scope. It also puts refresh tokens in our
-- database, which is the exact opposite of the reason the Android path reads
-- on-device (architecture section 2, decision 3).
--
-- Every major calendar already publishes a secret iCal URL. The user pastes
-- it once. We never ask for a password, never hold a token, and they can
-- invalidate the link themselves from their own calendar settings without
-- telling us. That last property is worth more than the convenience of OAuth.
--
-- KNOWN LIMITATION, and it must be said in the UI: Google refreshes private
-- ICS feeds slowly — up to 24 hours. Fine for a trip in a fortnight, not fine
-- for "who is free tomorrow". The Android path stays the good one.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Feeds
-- ---------------------------------------------------------------------------
-- The URL is a bearer credential: anyone holding it can read that calendar.
-- So it is stored encrypted, and the key lives in the Edge Function's
-- environment rather than in the database. A dump of this table on its own is
-- therefore worthless — which is not true of pgcrypto with a key kept in a
-- table, and not true of a plain-text column however tight the RLS.
--
-- Nothing here is readable by `authenticated` at all: the client talks to
-- my_calendar_feeds() and never sees a cipher.
create table if not exists calendar_feeds (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references profiles on delete cascade,

  -- What the user calls it. Free text, theirs.
  label          text not null check (char_length(label) between 1 and 60),
  -- Host only, for display: "calendar.google.com". Never the path, because
  -- the path IS the secret.
  host           text not null,

  -- base64(iv || AES-GCM ciphertext). Opaque to Postgres by design.
  url_cipher     text not null,
  -- sha256 of the normalised URL. Lets us reject a duplicate and find a feed
  -- to delete without ever decrypting one.
  url_hash       bytea not null,

  last_synced_at timestamptz,
  -- The provider's own words when a fetch fails. "404" and "this feed was
  -- revoked" need different reactions from the user, so we do not flatten
  -- them into "something went wrong".
  last_error     text,
  created_at     timestamptz not null default now(),

  unique (user_id, url_hash)
);

create index if not exists calendar_feeds_user_idx on calendar_feeds (user_id);

alter table calendar_feeds enable row level security;
-- No policies, deliberately. Service role only; the client uses the RPCs
-- below. Same reasoning as busy_intervals: a table nobody can SELECT cannot
-- leak through a future mistake in a SELECT policy.

comment on table calendar_feeds is
  'Secret iCal subscription URLs, encrypted with a key held only by the '
  'ical-sync Edge Function. Not readable by any user role.';

-- ---------------------------------------------------------------------------
-- 2. Where an interval came from
-- ---------------------------------------------------------------------------
-- 'ical' joins 'calendar' and 'manual'. All three still replace each other
-- per (trip, user): merging two sources has no correct answer when one says
-- free and the other says busy.
alter table busy_intervals drop constraint if exists busy_intervals_source_kind_check;
alter table busy_intervals
  add constraint busy_intervals_source_kind_check
  check (source_kind in ('calendar', 'manual', 'ical'));

-- ---------------------------------------------------------------------------
-- 3. What the client may know about its own feeds
-- ---------------------------------------------------------------------------
-- Everything except the one field that matters. The user does not need the
-- URL back — they pasted it, and if they lose it they can get a new one from
-- their calendar in less time than a "reveal" button would take to build.
create or replace function my_calendar_feeds()
returns table (
  id             uuid,
  label          text,
  host           text,
  last_synced_at timestamptz,
  last_error     text,
  created_at     timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select f.id, f.label, f.host, f.last_synced_at, f.last_error, f.created_at
  from calendar_feeds f
  where f.user_id = auth.uid()
  order by f.created_at;
$$;

create or replace function delete_calendar_feed(p_feed uuid)
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

  -- Ownership is checked here rather than trusted from the client, because
  -- security definer means RLS is not going to do it for us.
  delete from calendar_feeds where id = p_feed and user_id = v_user;
end;
$$;

grant execute on function my_calendar_feeds()          to authenticated;
grant execute on function delete_calendar_feed(uuid)   to authenticated;

-- ---------------------------------------------------------------------------
-- 4. What the Edge Function needs
-- ---------------------------------------------------------------------------
-- One call, membership guarded, so the function never has to decide who may
-- read a trip. Returns the window to clip to and the trip's timezone, which
-- is what floating iCal times have to be interpreted in.
create or replace function ical_sync_request(p_trip uuid)
returns table (
  window_start timestamptz,
  window_end   timestamptz,
  tz           text
)
language sql
security definer
set search_path = public
stable
as $$
  select lower(t.date_window), upper(t.date_window), t.timezone
  from trips t
  where t.id = p_trip and is_trip_member(p_trip);
$$;

grant execute on function ical_sync_request(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Guardrail
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
