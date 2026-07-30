-- ============================================================================
-- PlanTo — initial schema
-- Architecture section 9. Apply with: supabase db push
-- ============================================================================

create extension if not exists postgis;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------- helpers --
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- --------------------------------------------------------------- identity --
create table profiles (
  id              uuid primary key references auth.users on delete cascade,
  display_name    text not null check (char_length(display_name) between 1 and 40),
  -- Czech past tense agrees with gender ("se připojil" / "se připojila").
  -- Without this the app cannot form a grammatical sentence about a user.
  gender          text check (gender in ('m','f','x')),
  avatar_url      text,
  home_city       text,
  home_point      geography(point, 4326),
  locale          text not null default 'cs',
  currency        char(3) not null default 'CZK',
  is_anonymous    boolean not null default false,
  plan            text not null default 'free' check (plan in ('free','pro')),
  plan_until      timestamptz,
  ai_preview_used boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create trigger profiles_updated before update on profiles
  for each row execute function set_updated_at();

-- ----------------------------------------------------------- destinations --
-- Sourced from Wikidata (CC0), NOT OpenStreetMap. Extracting a curated table
-- from OSM would make it an ODbL Derivative Database with share-alike
-- obligations. See the cost register, section C1.
create table destinations (
  id                     uuid primary key default gen_random_uuid(),
  slug                   text unique not null,
  name                   text not null,
  name_i18n              jsonb not null default '{}',
  country                char(2) not null,
  region                 text,
  point                  geography(point, 4326) not null,
  nearest_stop_id        text,
  elevation_m            int,
  tags                   text[] not null default '{}',
  activity_profile       text not null default 'general',
  typical_duration_hours numeric(3,1),
  entrance_fee           numeric(8,2) default 0,
  currency               char(3) default 'CZK',
  best_months            int[] not null default '{1,2,3,4,5,6,7,8,9,10,11,12}',
  difficulty             int check (difficulty between 1 and 5),
  description_cs         text,   -- written by us; never copied from Wikipedia
  description_en         text,
  photo_url              text,
  source                 text,   -- 'wikidata:Q123'
  quality                int not null default 3 check (quality between 1 and 5),
  updated_at             timestamptz not null default now()
);
create index destinations_point_idx on destinations using gist (point);
create index destinations_tags_idx  on destinations using gin (tags);

-- ------------------------------------------------------------------ trips --
do $$ begin
  create type trip_status as enum ('draft','planning','date_locked','confirmed','completed','cancelled');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type transport_pref as enum ('public','car','either');
exception when duplicate_object then null;
end $$;

create table trips (
  id                uuid primary key default gen_random_uuid(),
  created_by        uuid not null references profiles on delete restrict,
  title             text not null check (char_length(title) between 1 and 80),
  description       text check (char_length(description) <= 500),
  status            trip_status not null default 'draft',
  origin_label      text not null,
  origin_point      geography(point, 4326) not null,
  destination_id    uuid references destinations,
  destination_free  text,
  -- `window` is a reserved keyword in PostgreSQL, hence the prefix.
  date_window       tstzrange not null,
  duration_days     int check (duration_days between 1 and 14),
  duration_flexible boolean not null default false,
  transport         transport_pref not null default 'either',
  budget_per_person numeric(10,2) check (budget_per_person >= 0),
  currency          char(3) not null default 'CZK',
  activity_tags     text[] not null default '{}',
  earliest_wake     time,
  locked_date       daterange,
  notes             text,
  timezone          text not null default 'Europe/Prague',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint date_window_not_empty check (not isempty(date_window))
);
create index trips_date_window_idx on trips using gist (date_window);
create index trips_creator_idx on trips (created_by, status);
create trigger trips_updated before update on trips
  for each row execute function set_updated_at();

do $$ begin
  create type participant_role as enum ('organiser','member');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type participant_status as enum ('invited','joined','confirmed','declined');
exception when duplicate_object then null;
end $$;

create table trip_participants (
  trip_id         uuid not null references trips on delete cascade,
  user_id         uuid not null references profiles on delete cascade,
  role            participant_role   not null default 'member',
  status          participant_status not null default 'joined',
  calendar_shared boolean not null default false,
  joined_at       timestamptz not null default now(),
  primary key (trip_id, user_id)
);
create index trip_participants_user_idx on trip_participants (user_id);

create table invites (
  id         uuid primary key default gen_random_uuid(),
  trip_id    uuid not null references trips on delete cascade,
  -- sha256 of the token. The raw token exists only in the shared URL, so a
  -- database leak does not hand out working invite links.
  token_hash bytea not null unique,
  created_by uuid not null references profiles,
  expires_at timestamptz not null default now() + interval '30 days',
  max_uses   int check (max_uses > 0),
  uses       int not null default 0,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------- availability --
create table calendar_connections (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles on delete cascade,
  source      text not null check (source in ('device_android','device_ios','google','microsoft','manual')),
  label       text,
  external_id text,
  last_synced timestamptz,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (user_id, source, external_id)
);

-- ONLY busy blocks. There is deliberately no column for a title, location or
-- attendee: the privacy promise is enforced by the schema, not by discipline.
create table busy_intervals (
  id         bigint generated always as identity primary key,
  trip_id    uuid not null references trips on delete cascade,
  user_id    uuid not null references profiles on delete cascade,
  period     tstzrange not null,
  is_all_day boolean not null default false,
  source_id  uuid references calendar_connections on delete cascade,
  created_at timestamptz not null default now(),
  constraint busy_not_empty check (not isempty(period))
);
create index busy_period_idx on busy_intervals using gist (period);
create index busy_trip_user_idx on busy_intervals (trip_id, user_id);

-- ------------------------------------------------------- reference tables --
create table holidays (
  country char(2) not null,
  date    date not null,
  name    text not null,
  primary key (country, date)
);

create table app_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

insert into app_config (key, value) values
  ('ai_enabled',            'true'::jsonb),
  ('ai_monthly_budget_eur', '10'::jsonb),
  ('ai_preview_enabled',    'true'::jsonb)
on conflict (key) do nothing;
