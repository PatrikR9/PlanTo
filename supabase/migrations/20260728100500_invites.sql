-- ============================================================================
-- M3 — invite links. Architecture section 10.2.
--
-- Implemented as security-definer RPCs rather than Edge Functions. The
-- architecture called for an Edge Function, but everything it needed to do
-- here is database work: hash a token, check expiry, insert a membership row.
-- Keeping it in SQL means no separate deploy step, no cold start, and the
-- validation sits next to the data it validates. If rate limiting outgrows
-- what a table can do, this moves to an Edge Function without the client
-- noticing.
-- ============================================================================

create extension if not exists pgcrypto;

-- Attempts are logged so a token cannot be brute-forced quietly.
create table invite_attempts (
  id         bigint generated always as identity primary key,
  token_hash bytea,
  ok         boolean not null,
  at         timestamptz not null default now()
);
create index invite_attempts_recent_idx on invite_attempts (at desc);
alter table invite_attempts enable row level security;
-- no policies: service role only

-- ---------------------------------------------------------------- create ---
create or replace function create_invite(
  p_trip uuid,
  p_expires_days int default 30,
  p_max_uses int default null
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token text;
begin
  if not is_trip_organiser(p_trip) then
    raise exception 'only organisers can invite' using errcode = '42501';
  end if;

  -- 128 bits, url-safe. Returned exactly once: only the hash is stored, so a
  -- database leak does not hand out working invite links.
  v_token := translate(encode(gen_random_bytes(16), 'base64'), '+/=', '-_');

  insert into invites (trip_id, token_hash, created_by, expires_at, max_uses)
  values (
    p_trip,
    digest(v_token, 'sha256'),
    auth.uid(),
    now() + make_interval(days => p_expires_days),
    p_max_uses
  );

  return v_token;
end;
$$;

-- --------------------------------------------------------------- preview ---
-- Callable by `anon`: the invite preview must render for someone who has
-- never opened the app. It returns only what a poster on a noticeboard would
-- show — never participant names, never the destination coordinates.
create or replace function preview_invite(p_token text)
returns table (
  trip_id           uuid,
  title             text,
  origin_label      text,
  window_start      timestamptz,
  window_end        timestamptz,
  duration_days     int,
  participant_count int,
  organiser_name    text,
  already_member    boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash bytea := digest(p_token, 'sha256');
  v_recent int;
begin
  select count(*) into v_recent
  from invite_attempts
  where at > now() - interval '1 hour' and not ok;

  if v_recent > 200 then
    raise exception 'too many attempts' using errcode = '42901';
  end if;

  return query
  select t.id, t.title, t.origin_label,
         lower(t.date_window), upper(t.date_window), t.duration_days,
         (select count(*)::int from trip_participants p where p.trip_id = t.id),
         coalesce(pr.display_name, 'Organizátor'),
         exists (
           select 1 from trip_participants p
           where p.trip_id = t.id and p.user_id = auth.uid()
         )
  from invites i
  join trips t     on t.id = i.trip_id
  left join profiles pr on pr.id = i.created_by
  where i.token_hash = v_hash
    and i.revoked_at is null
    and i.expires_at > now()
    and (i.max_uses is null or i.uses < i.max_uses);

  insert into invite_attempts (token_hash, ok) values (v_hash, found);
end;
$$;

-- ---------------------------------------------------------------- redeem ---
create or replace function redeem_invite(p_token text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash bytea := digest(p_token, 'sha256');
  v_trip uuid;
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- FOR UPDATE so two taps on a max_uses-limited link cannot both win.
  select i.trip_id into v_trip
  from invites i
  where i.token_hash = v_hash
    and i.revoked_at is null
    and i.expires_at > now()
    and (i.max_uses is null or i.uses < i.max_uses)
  for update;

  if v_trip is null then
    insert into invite_attempts (token_hash, ok) values (v_hash, false);
    raise exception 'invalid or expired invite' using errcode = '22023';
  end if;

  insert into trip_participants (trip_id, user_id, role, status)
  values (v_trip, v_user, 'member', 'joined')
  on conflict (trip_id, user_id) do nothing;

  -- Only a genuinely new membership consumes a use, so re-opening your own
  -- link does not burn the quota.
  if found then
    update invites set uses = uses + 1 where token_hash = v_hash;
  end if;

  insert into invite_attempts (token_hash, ok) values (v_hash, true);
  return v_trip;
end;
$$;

-- ---------------------------------------------------------------- revoke ---
create or replace function revoke_invite(p_trip uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_trip_organiser(p_trip) then
    raise exception 'only organisers can revoke' using errcode = '42501';
  end if;
  update invites set revoked_at = now()
  where trip_id = p_trip and revoked_at is null;
end;
$$;

grant execute on function create_invite(uuid, int, int)  to authenticated;
grant execute on function preview_invite(text)           to anon, authenticated;
grant execute on function redeem_invite(text)            to authenticated;
grant execute on function revoke_invite(uuid)            to authenticated;
