-- ============================================================================
-- M1 — auth wiring. Architecture section 10.
-- ============================================================================

-- Every auth.users row gets a profiles row, immediately and unconditionally.
--
-- Doing this in the database rather than the app removes a whole class of bug:
-- a user whose sign-up succeeded but whose profile insert failed (app killed,
-- network dropped, RLS misconfigured) would otherwise exist in auth but be
-- invisible everywhere else, and every join would silently drop them.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, is_anonymous, locale)
  values (
    new.id,
    -- Best available name, in order: what the client passed at sign-up, the
    -- OAuth provider's name, the local part of the email, then a fallback.
    coalesce(
      nullif(new.raw_user_meta_data ->> 'display_name', ''),
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      nullif(new.raw_user_meta_data ->> 'name', ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'Cestovatel'
    ),
    new.is_anonymous,
    coalesce(nullif(new.raw_user_meta_data ->> 'locale', ''), 'cs')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- An anonymous user who later links a Google identity stops being anonymous.
-- Keeping profiles.is_anonymous in sync matters because anonymous accounts are
-- garbage-collected after 60 days (architecture section 9.8) and we must not
-- delete someone who has since signed up properly.
create or replace function sync_profile_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_anonymous is distinct from old.is_anonymous then
    update public.profiles
       set is_anonymous = new.is_anonymous
     where id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_updated on auth.users;
create trigger on_auth_user_updated
  after update on auth.users
  for each row execute function sync_profile_identity();

-- Backfill anyone who signed up before this migration.
insert into public.profiles (id, display_name, is_anonymous, locale)
select u.id,
       coalesce(
         nullif(u.raw_user_meta_data ->> 'display_name', ''),
         nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
         'Cestovatel'
       ),
       u.is_anonymous,
       'cs'
from auth.users u
on conflict (id) do nothing;

-- The trigger is security definer so it does not need a policy, but a user
-- repairing their own missing profile is a reasonable fallback.
create policy profiles_insert_self on profiles
  for insert with check (id = auth.uid());
