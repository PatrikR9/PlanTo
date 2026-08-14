-- ============================================================================
-- M13.1 — jedna délka, editovatelný výlet, meeting mód.
--
-- Tři věci, jedna migrace, protože stojí na stejném sloupci:
--   1. duration_minutes je nově jediný zdroj pravdy o délce. duration_days,
--      granularity a slot_minutes se z něj odvozují triggerem, takže devět
--      funkcí, které je čtou, zůstává beze změny.
--   2. update_trip(jsonb) — organizátor smí přepsat, co při zakládání zadal.
--      create_trip se mění na stejný tvar, čímž končí dropování přetížení.
--   3. trips.kind = 'meeting' — schůzka s kolegy je výlet bez místa. Stejné
--      pozvánky, stejný solver, jen bez cíle, dopravy, počasí a balení.
--
-- Nesahá na trip_candidates, transport_options ani estimate_trip_cost.
-- Etapy cesty (trip_legs) jsou M13.2 — viz M13_FLEXIBILITA.md.
--
-- Apply with: supabase db push   (až po VERIFY.md — šest migrací před touhle
-- nikdy neběželo a smíchat je znamená nevědět, která spadla)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Délka v minutách
-- ---------------------------------------------------------------------------
alter table trips
  add column if not exists duration_minutes int;

-- Backfill dřív než NOT NULL. Denní výlet dostane celé dny, časový svou délku
-- slotu — obojí projde triggerem níž na identické hodnoty, jaké má teď.
update trips
   set duration_minutes = case
         when granularity = 'time' then coalesce(slot_minutes, 120)
         else coalesce(duration_days, 1) * 1440
       end
 where duration_minutes is null;

alter table trips
  alter column duration_minutes set default 1440,
  alter column duration_minutes set not null;

-- Strop je 30 dní, ne 14. Dovolená s přejížděním se do dvou týdnů nevejde a
-- vyšší číslo nic nestojí: solver stejně limituje okno, ne délku.
alter table trips drop constraint if exists trips_duration_minutes_range;
alter table trips add constraint trips_duration_minutes_range
  check (duration_minutes between 15 and 43200);

-- Původní check byl `duration_days between 1 and 14`. Sloupec se ruší, ne
-- zužuje — od téhle migrace ho zapisuje výhradně trigger.
alter table trips drop constraint if exists trips_duration_days_check;
alter table trips add constraint trips_duration_days_derived
  check (duration_days between 1 and 30);

comment on column trips.duration_minutes is
  'Jak dlouho výlet trvá. Jediný zdroj pravdy o délce: duration_days, '
  'granularity a slot_minutes se z něj odvozují v trips_derive_duration().';

create or replace function trips_derive_duration()
returns trigger
language plpgsql
as $$
begin
  -- ceil, ne round: čtyřicetihodinová akce zabere dva dny, ne jeden a půl.
  new.duration_days := greatest(1, ceil(new.duration_minutes / 1440.0)::int);

  if new.duration_minutes < 1440 then
    -- Pod den má odpovědí konkrétní čas, ne datum. Délka slotu JE délka akce;
    -- držet je zvlášť znamenalo, že šlo uložit denní výlet se slot_minutes,
    -- která nic neřídí.
    new.granularity  := 'time';
    new.slot_minutes := new.duration_minutes;
  else
    new.granularity  := 'day';
    new.slot_minutes := null;
  end if;

  return new;
end;
$$;

drop trigger if exists trips_derive_duration_trg on trips;
create trigger trips_derive_duration_trg
  before insert or update on trips
  for each row execute function trips_derive_duration();

-- Projet trigger přes existující řádky. Nemá co změnit — a právě to je ta
-- kontrola, kterou tenhle řádek dělá.
update trips set duration_minutes = duration_minutes;

-- ---------------------------------------------------------------------------
-- 2. Meeting: výlet bez místa
-- ---------------------------------------------------------------------------
do $$ begin
  create type trip_kind as enum ('trip', 'meeting');
exception when duplicate_object then null;
end $$;

alter table trips
  add column if not exists kind trip_kind not null default 'trip';

comment on column trips.kind is
  'trip = plánuje se cesta někam; meeting = jen společný čas. Meeting nemá '
  'původ ani cíl a nedotýká se dopravy, počasí, nákladů ani balení.';

-- Podmínka se nezeslabuje, jen se stěhuje ze sloupce do check: výlet původ mít
-- musí dál, meeting ho mít nesmí kde vzít.
alter table trips alter column origin_label drop not null;
alter table trips alter column origin_point drop not null;

alter table trips drop constraint if exists trips_origin_required_for_trip;
alter table trips add constraint trips_origin_required_for_trip
  check (
    kind = 'meeting'
    or (origin_label is not null and origin_point is not null)
  );

alter table trips drop constraint if exists trips_meeting_has_no_destination;
alter table trips add constraint trips_meeting_has_no_destination
  check (
    kind = 'trip'
    or (destination_id is null
        and destination_free is null
        and destination_point is null
        and destination_place_id is null)
  );

-- Bez tohohle projdou tři nully coalescí jako platný bod a Termíny ukážou
-- skóre počasí pro místo, které neexistuje. Nula řádků je odpověď "nevíme",
-- kterou už zbytek řetězce umí (chybějící předpověď ≠ hezky).
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
  where t.id = p_trip
    and t.kind = 'trip'
    and is_trip_member(p_trip);
$$;

revoke execute on function _trip_weather_point(uuid) from public;

-- ---------------------------------------------------------------------------
-- 3. Zakládání a editace přes jeden jsonb
-- ---------------------------------------------------------------------------
-- create_trip měl devatenáct parametrů a každé další pole znamenalo
-- `drop function` s přesnou signaturou — a s ním padal grant (past ze
-- session 2, dvakrát). Jeden jsonb argument signaturu nikdy nezmění.
--
-- Klíče: title, description, origin_place, origin_label, origin_lat,
-- origin_lon, window_start, window_end, duration_minutes, transport,
-- budget_per_person, currency, activity_tags, earliest_wake,
-- slot_step_minutes, day_start, day_end, kind.

create or replace function _assert_trip_window(
  p_start timestamptz,
  p_end   timestamptz,
  p_duration_minutes int
)
returns void
language plpgsql
stable   -- ::date na timestamptz čte TimeZone, takže immutable by byla lež
as $$
declare
  v_days int;
begin
  if p_end <= p_start then
    raise exception 'window end must be after start' using errcode = '22000';
  end if;

  v_days := (p_end::date - p_start::date) + 1;

  -- Time mód generuje řádek na (den × slot × účastník). Rok při kroku 15 minut
  -- je 35 000 slotů a obrazovka, kterou nikdo nepřečte.
  if p_duration_minutes < 1440 and v_days > 42 then
    raise exception 'a time-based trip cannot span more than 6 weeks'
      using errcode = '22000';
  end if;

  -- Výlet se musí do okna vejít celý, jinak nemá solver co nabídnout.
  if p_duration_minutes >= 1440
     and ceil(p_duration_minutes / 1440.0) > v_days then
    raise exception 'the trip is longer than the window it may fall in'
      using errcode = '22000';
  end if;
end;
$$;

drop function if exists create_trip(
  text, text, double precision, double precision, timestamptz, timestamptz,
  int, transport_pref, numeric, text[], text, time, char(3),
  text, int, int, time, time, uuid
);

create or replace function create_trip(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip     uuid;
  v_user     uuid := auth.uid();
  v_kind     trip_kind := coalesce((p->>'kind')::trip_kind, 'trip');
  v_label    text := p->>'origin_label';
  v_point    geography;
  v_place    uuid := (p->>'origin_place')::uuid;
  v_start    timestamptz := (p->>'window_start')::timestamptz;
  v_end      timestamptz := (p->>'window_end')::timestamptz;
  v_duration int := coalesce((p->>'duration_minutes')::int, 1440);
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if exists (select 1 from auth.users where id = v_user and is_anonymous) then
    raise exception 'anonymous users cannot create trips' using errcode = '42501';
  end if;

  if coalesce(trim(p->>'title'), '') = '' then
    raise exception 'a trip needs a title' using errcode = '22000';
  end if;

  if v_start is null or v_end is null then
    raise exception 'a trip needs a window' using errcode = '22000';
  end if;

  perform _assert_trip_window(v_start, v_end, v_duration);

  if v_kind = 'trip' then
    -- Zastávka vyhrává nad poslanými souřadnicemi. Klient posílá obojí, aby
    -- výlet šel založit i s prázdnou databází zastávek.
    if v_place is not null then
      select pl.name, pl.point into v_label, v_point
      from transit_places pl where pl.id = v_place;
      if not found then
        raise exception 'unknown stop %', v_place using errcode = '22000';
      end if;
    elsif p ? 'origin_lat' and p ? 'origin_lon' then
      v_point := st_setsrid(
        st_makepoint((p->>'origin_lon')::double precision,
                     (p->>'origin_lat')::double precision), 4326)::geography;
    else
      raise exception 'a trip needs an origin' using errcode = '22000';
    end if;
  else
    -- Meeting nemá odkud vyjet. Případný původ poslaný omylem se zahazuje tady,
    -- ne až na checku — chyba schématu by uživateli neřekla nic.
    v_label := null;
    v_point := null;
    v_place := null;
  end if;

  insert into trips (
    created_by, title, description, status, kind,
    origin_label, origin_point, origin_place_id, date_window,
    duration_minutes, transport, budget_per_person, currency,
    activity_tags, earliest_wake,
    slot_step_minutes, day_start, day_end
  ) values (
    v_user, p->>'title', p->>'description', 'planning', v_kind,
    v_label, v_point, v_place,
    tstzrange(v_start, v_end, '[)'),
    v_duration,
    coalesce((p->>'transport')::transport_pref, 'either'),
    (p->>'budget_per_person')::numeric,
    coalesce(p->>'currency', 'CZK'),
    case
      when v_kind = 'meeting' then '{}'::text[]
      else coalesce(
        (select array_agg(x) from jsonb_array_elements_text(p->'activity_tags') x),
        '{}')
    end,
    (p->>'earliest_wake')::time,
    coalesce((p->>'slot_step_minutes')::int, 30),
    coalesce((p->>'day_start')::time, '07:00'),
    coalesce((p->>'day_end')::time, '21:00')
  )
  returning id into v_trip;

  insert into trip_participants (trip_id, user_id, role, status)
  values (v_trip, v_user, 'organiser', 'confirmed');

  return v_trip;
end;
$$;

grant execute on function create_trip(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. update_trip — patch, ne replace
-- ---------------------------------------------------------------------------
-- Chybějící klíč = neměnit. Klíč s JSON null = vymazat. Nullable parametry by
-- ty dva případy nerozlišily, a "nesahej na rozpočet" versus "rozpočet zruš"
-- je přesně ten rozdíl, na kterém by se to podepsalo.
--
-- Plán, náklady a balení se nikde neinvalidují schválně: jsou to čtecí funkce,
-- ne uložené řádky. Jediný uložený odvozený stav jsou hlasy a zámek.
create or replace function update_trip(p_trip uuid, p_patch jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  t          trips%rowtype;
  v_window   tstzrange;
  v_duration int;
  v_step     int;
  v_mode_flip boolean;
begin
  -- security definer obchází RLS, takže kontrola musí být tady, ne v politice.
  if not is_trip_organiser(p_trip) then
    raise exception 'only the organiser can edit the trip' using errcode = '42501';
  end if;

  select * into t from trips where id = p_trip;
  if not found then
    raise exception 'unknown trip' using errcode = '22000';
  end if;

  v_window := tstzrange(
    coalesce((p_patch->>'window_start')::timestamptz, lower(t.date_window)),
    coalesce((p_patch->>'window_end')::timestamptz,   upper(t.date_window)),
    '[)');

  v_duration := coalesce((p_patch->>'duration_minutes')::int, t.duration_minutes);
  v_step     := coalesce((p_patch->>'slot_step_minutes')::int, t.slot_step_minutes);

  perform _assert_trip_window(lower(v_window), upper(v_window), v_duration);

  if p_patch ? 'title' and coalesce(trim(p_patch->>'title'), '') = '' then
    raise exception 'a trip needs a title' using errcode = '22000';
  end if;

  if p_patch ? 'kind' then
    raise exception 'a trip cannot change kind' using errcode = '22000';
  end if;

  v_mode_flip := (v_duration < 1440) <> (t.duration_minutes < 1440);

  update trips set
    title = case when p_patch ? 'title'
                 then p_patch->>'title' else title end,
    description = case when p_patch ? 'description'
                 then p_patch->>'description' else description end,
    date_window = v_window,
    duration_minutes = v_duration,
    slot_step_minutes = v_step,
    day_start = coalesce((p_patch->>'day_start')::time, day_start),
    day_end   = coalesce((p_patch->>'day_end')::time, day_end),
    transport = case when p_patch ? 'transport'
                 then coalesce((p_patch->>'transport')::transport_pref, 'either')
                 else transport end,
    budget_per_person = case when p_patch ? 'budget_per_person'
                 then (p_patch->>'budget_per_person')::numeric
                 else budget_per_person end,
    currency = coalesce(p_patch->>'currency', currency),
    earliest_wake = case when p_patch ? 'earliest_wake'
                 then (p_patch->>'earliest_wake')::time
                 else earliest_wake end,
    activity_tags = case
                 when kind = 'meeting' then '{}'::text[]
                 when p_patch ? 'activity_tags' then coalesce(
                   (select array_agg(x)
                      from jsonb_array_elements_text(p_patch->'activity_tags') x),
                   '{}')
                 else activity_tags end
  where id = p_trip;

  -- ---- invalidace --------------------------------------------------------
  -- Hlas pro termín, který po zúžení okna neexistuje, není hlas.
  delete from date_votes v
   where v.trip_id = p_trip
     and not (v.slot_start >= lower(v_window) and v.slot_start < upper(v_window));

  -- Přeskok hranice 24 h nebo změna kroku posune celou mřížku kandidátů. Hlasy
  -- by pak visely na časech, které se už nikomu nenabídnou.
  if v_mode_flip or v_step <> t.slot_step_minutes then
    delete from date_votes where trip_id = p_trip;
  end if;

  -- Zámek si drží začátek a přebírá novou délku.
  update trips
     set locked_range = tstzrange(
           lower(locked_range),
           lower(locked_range) + case
             when duration_minutes < 1440
               then make_interval(mins => duration_minutes)
             else make_interval(days => duration_days)
           end, '[)')
   where id = p_trip and locked_range is not null;

  update trips
     set locked_range = null,
         status = 'planning'
   where id = p_trip
     and locked_range is not null
     and not (locked_range && date_window);
end;
$$;

grant execute on function update_trip(uuid, jsonb) to authenticated;

comment on function update_trip is
  'Patch výletu organizátorem. Chybějící klíč nemění nic, JSON null maže. '
  'Maže hlasy mimo nové okno a při posunu mřížky; zámek přepočítá nebo zruší.';

-- ---------------------------------------------------------------------------
-- 5. Náhled pozvánky
-- ---------------------------------------------------------------------------
-- Vracel origin_label bez ohledu na druh. U setkání je null, takže klient by
-- na něm spadl při přetypování — a to na jediné obrazovce, která se ukazuje
-- nepřihlášenému člověku z odkazu ve skupinovém chatu.
--
-- Změna návratového typu vyžaduje drop, a drop bere s sebou grant (past 1).
drop function if exists preview_invite(text);

create function preview_invite(p_token text)
returns table (
  trip_id           uuid,
  kind              text,
  title             text,
  origin_label      text,
  window_start      timestamptz,
  window_end        timestamptz,
  duration_days     int,
  duration_minutes  int,
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
  select t.id, t.kind::text, t.title, t.origin_label,
         lower(t.date_window), upper(t.date_window),
         t.duration_days, t.duration_minutes,
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

grant execute on function preview_invite(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Read model
-- ---------------------------------------------------------------------------
-- Znovu vytvořený, ne nahrazený: přibývají sloupce doprostřed pořadí a
-- CREATE OR REPLACE VIEW je umí přidat jen na konec (past 8).
drop view if exists trips_list;

create view trips_list
with (security_invoker = true)
as
select
  t.id,
  t.kind,
  t.title,
  t.description,
  t.status,
  t.origin_label,
  st_y(t.origin_point::geometry) as origin_lat,
  st_x(t.origin_point::geometry) as origin_lon,
  t.origin_place_id,
  lower(t.date_window)           as window_start,
  upper(t.date_window)           as window_end,
  t.duration_minutes,
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
  t.destination_place_id,
  t.created_by,
  t.created_at,
  t.granularity,
  t.slot_minutes,
  t.slot_step_minutes,
  t.day_start,
  t.day_end,
  lower(t.locked_range) as locked_start,
  upper(t.locked_range) as locked_end,
  (select count(*) from trip_participants pp where pp.trip_id = t.id)
    as participant_count,
  (select count(*) from trip_participants pp
    where pp.trip_id = t.id and pp.calendar_shared) as calendar_shared_count,
  (select pp.role from trip_participants pp
    where pp.trip_id = t.id and pp.user_id = auth.uid()) as my_role
from trips t;

grant select on trips_list to authenticated;
