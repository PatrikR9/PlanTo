-- Emergency reset for a DEVELOPMENT project only.
--
-- `supabase db push` wraps each migration in a transaction, so a failed push
-- normally rolls itself back and you can simply re-run it. Use this only if
-- the next push complains that something already exists.
--
-- NEVER run this against production.
drop schema if exists public cascade;
create schema public;
grant usage on schema public to anon, authenticated, service_role;
grant all on schema public to postgres;

drop type if exists trip_status cascade;
drop type if exists transport_pref cascade;
drop type if exists participant_role cascade;
drop type if exists participant_status cascade;
drop type if exists vote_value cascade;
