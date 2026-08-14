-- M13.1 — délka v minutách, editace výletu, meeting mód.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/flexible_test.sql
--
-- PROČ TENHLE SOUBOR EXISTUJE
--
-- duration_minutes je nově jediný zdroj pravdy o délce a tři sloupce, na
-- kterých stojí devět funkcí, se z něj odvozují triggerem. Chyba v tom
-- triggeru se neprojeví jako pád, ale jako výlet, který se plánuje na jiný
-- počet dní, než si uživatel nastavil — a to nikdo nepozná od stolu.
--
-- Druhá polovina hlídá invalidaci v update_trip. Smazat víc hlasů, než je
-- nutné, znamená zahodit rozhodnutí pěti lidí kvůli změně rozpočtu.
--
-- Běží jako `authenticated` všude, kde se testuje RPC: chyba v grantech nebo
-- v kontrole organizátora je pro roli postgres z principu neviditelná.

begin;
set local role postgres;

insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at,
                        created_at, updated_at)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'a@test.cz', now(), now(), now()),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'b@test.cz', now(), now(), now());

insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'Anna'),
  ('22222222-2222-2222-2222-222222222222', 'Bob');

-- ============================================================================
-- 1. Trigger odvozuje délku na hranicích
-- ============================================================================
-- 1439 a 1440 jsou ta jediná dvojice, kde se mění mód. Kdyby byla podmínka
-- <= místo <, celodenní výlet by se plánoval po slotech uvnitř dne.
do $$
declare
  r        record;
  v_cases  int[][] := array[
    -- minuty, čekané dny, čekaná granularita (1 = time, 0 = day)
    array[15,    1, 1],
    array[120,   1, 1],
    array[1439,  1, 1],
    array[1440,  1, 0],
    array[1441,  2, 0],   -- ceil, ne round: 24 h a minuta zabere dva dny
    array[2880,  2, 0],
    array[10080, 7, 0],
    array[43200, 30, 0]
  ];
  v_case   int[];
  v_id     uuid;
begin
  foreach v_case slice 1 in array v_cases loop
    insert into trips (created_by, title, origin_label, origin_point,
                       date_window, duration_minutes)
    values ('11111111-1111-1111-1111-111111111111', 'T',
            'Praha', st_point(14.42, 50.08)::geography,
            tstzrange('2026-09-01 00:00+02', '2026-12-01 00:00+01'),
            v_case[1])
    returning id into v_id;

    select duration_days, granularity, slot_minutes into r
    from trips where id = v_id;

    if r.duration_days <> v_case[2] then
      raise exception '% minut => % dnu, cekal jsem %',
        v_case[1], r.duration_days, v_case[2];
    end if;

    if (r.granularity = 'time')::int <> v_case[3] then
      raise exception '% minut => granularita %', v_case[1], r.granularity;
    end if;

    -- slot_minutes existuje právě v time módu a rovná se délce. Kdyby zůstala
    -- po přepnutí na dny viset, trip_candidates by ji použila.
    if v_case[3] = 1 and coalesce(r.slot_minutes, -1) <> v_case[1] then
      raise exception '% minut => slot_minutes %', v_case[1], r.slot_minutes;
    end if;
    if v_case[3] = 0 and r.slot_minutes is not null then
      raise exception '% minut => slot_minutes % v dennim modu',
        v_case[1], r.slot_minutes;
    end if;

    delete from trips where id = v_id;
  end loop;
end $$;

-- Ruční zápis do odvozeného sloupce nesmí přežít. Kdyby přežil, vzniknou dvě
-- odpovědi na otázku, jak je výlet dlouhý.
do $$
declare
  v_id   uuid;
  v_days int;
begin
  insert into trips (created_by, title, origin_label, origin_point,
                     date_window, duration_minutes, duration_days)
  values ('11111111-1111-1111-1111-111111111111', 'T',
          'Praha', st_point(14.42, 50.08)::geography,
          tstzrange('2026-09-01 00:00+02', '2026-10-01 00:00+02'), 2880, 9)
  returning id into v_id;

  select duration_days into v_days from trips where id = v_id;
  if v_days <> 2 then
    raise exception 'rucne zapsanych 9 dnu prezilo: %', v_days;
  end if;
  delete from trips where id = v_id;
end $$;

-- ============================================================================
-- 2. Zakládání přes jsonb
-- ============================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare
  v_trip uuid;
  t      trips%rowtype;
begin
  v_trip := create_trip(jsonb_build_object(
    'title', 'Víkend na horách',
    'origin_label', 'Praha hl.n.',
    'origin_lat', 50.083, 'origin_lon', 14.435,
    'window_start', '2026-09-01 00:00+02',
    'window_end',   '2026-10-01 00:00+02',
    'duration_minutes', 2880,
    'activity_tags', jsonb_build_array('hiking')
  ));

  select * into t from trips where id = v_trip;
  if t.duration_days <> 2 or t.kind <> 'trip' or t.status <> 'planning' then
    raise exception 'create_trip: dny=%, kind=%, status=%',
      t.duration_days, t.kind, t.status;
  end if;

  -- Zakladatel je organizátor ve stejné transakci, jinak vznikne výlet,
  -- který nikdo nesmí editovat.
  if not exists (select 1 from trip_participants
                 where trip_id = v_trip
                   and user_id = '11111111-1111-1111-1111-111111111111'
                   and role = 'organiser') then
    raise exception 'zakladatel neni organizator';
  end if;
end $$;

-- Výlet bez původu neprojde; meeting bez původu ano.
do $$
declare v_id uuid;
begin
  begin
    v_id := create_trip(jsonb_build_object(
      'title', 'Bez puvodu',
      'window_start', '2026-09-01 00:00+02',
      'window_end',   '2026-09-10 00:00+02',
      'duration_minutes', 1440));
    raise exception 'REGRESE: vylet se zalozil bez puvodu';
  exception
    when sqlstate '22000' then null;
  end;
end $$;

do $$
declare
  v_id uuid;
  t    trips%rowtype;
begin
  v_id := create_trip(jsonb_build_object(
    'kind', 'meeting',
    'title', 'Sync s tymem',
    'window_start', '2026-09-01 00:00+02',
    'window_end',   '2026-09-10 00:00+02',
    'duration_minutes', 90,
    'activity_tags', jsonb_build_array('hiking')   -- musí se zahodit
  ));

  select * into t from trips where id = v_id;
  if t.origin_point is not null or t.origin_label is not null then
    raise exception 'meeting dostal puvod';
  end if;
  if array_length(t.activity_tags, 1) is not null then
    raise exception 'meeting si nechal aktivity: %', t.activity_tags;
  end if;
  if t.granularity <> 'time' or t.slot_minutes <> 90 then
    raise exception 'meeting: granularita=%, slot=%', t.granularity, t.slot_minutes;
  end if;

  -- Bez tohohle by Termíny ukázaly skóre počasí pro místo, které neexistuje.
  if exists (select 1 from _trip_weather_point(v_id)) then
    raise exception 'REGRESE: meeting ma bod pro pocasi';
  end if;
end $$;

-- Okno kratší než výlet nemá solveru co nabídnout.
do $$
declare v_id uuid;
begin
  begin
    v_id := create_trip(jsonb_build_object(
      'title', 'Tyden ve trech dnech',
      'origin_label', 'Praha', 'origin_lat', 50.08, 'origin_lon', 14.42,
      'window_start', '2026-09-01 00:00+02',
      'window_end',   '2026-09-04 00:00+02',
      'duration_minutes', 10080));
    raise exception 'REGRESE: sedmidenni vylet se vesel do tridenniho okna';
  exception
    when sqlstate '22000' then null;
  end;
end $$;

-- ============================================================================
-- 3. update_trip — kdo smí a co se maže
-- ============================================================================
set local role postgres;

insert into trips (id, created_by, title, origin_label, origin_point,
                   date_window, duration_minutes, timezone, budget_per_person)
values (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '11111111-1111-1111-1111-111111111111',
  'Editovatelny', 'Praha', st_point(14.42, 50.08)::geography,
  tstzrange('2026-09-01 00:00+02', '2026-10-01 00:00+02'), 1440,
  'Europe/Prague', 800
);

insert into trip_participants (trip_id, user_id, role) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '11111111-1111-1111-1111-111111111111', 'organiser'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '22222222-2222-2222-2222-222222222222', 'member');

insert into date_votes (trip_id, slot_start, user_id, vote) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '2026-09-05 00:00+02',
   '11111111-1111-1111-1111-111111111111', 'yes'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '2026-09-25 00:00+02',
   '22222222-2222-2222-2222-222222222222', 'yes');

set local role authenticated;

-- Člen, který není organizátor, editovat nesmí. security definer obchází RLS,
-- takže tohle je jediná obrana.
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
begin
  begin
    perform update_trip('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
                        '{"title":"Prepsano clenem"}'::jsonb);
    raise exception 'REGRESE: clen prepsal cizi vylet';
  exception
    when insufficient_privilege then null;
  end;
end $$;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- Změna, která se nedotýká termínů, nesmí sáhnout na hlasy.
select update_trip('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
                   '{"budget_per_person": 1200}'::jsonb);

do $$
declare v_n int;
begin
  select count(*) into v_n from date_votes
  where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if v_n <> 2 then
    raise exception 'zmena rozpoctu smazala hlasy: zbylo %', v_n;
  end if;
end $$;

-- JSON null maže, chybějící klíč nechává být. Kdyby se ty dva případy
-- slily, "nesahej na rozpočet" a "rozpočet zruš" by dělaly totéž.
select update_trip('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
                   '{"budget_per_person": null}'::jsonb);

do $$
declare v_b numeric; v_t text;
begin
  select budget_per_person, title into v_b, v_t
  from trips where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if v_b is not null then
    raise exception 'null nesmazal rozpocet: %', v_b;
  end if;
  if v_t <> 'Editovatelny' then
    raise exception 'chybejici klic prepsal nazev na %', v_t;
  end if;
end $$;

-- Zúžení okna smaže právě ty hlasy, které z něj vypadly.
select update_trip('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
                   '{"window_end": "2026-09-10 00:00+02"}'::jsonb);

do $$
declare v_n int; v_kept timestamptz;
begin
  select count(*), min(slot_start) into v_n, v_kept from date_votes
  where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if v_n <> 1 or v_kept <> '2026-09-05 00:00+02'::timestamptz then
    raise exception 'zuzeni okna: zbylo % hlasu, prvni %', v_n, v_kept;
  end if;
end $$;

-- Přeskok hranice 24 h posune celou mřížku, takže padají všechny hlasy.
select update_trip('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
                   '{"duration_minutes": 120}'::jsonb);

do $$
declare v_n int; v_g text;
begin
  select count(*) into v_n from date_votes
  where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  select granularity into v_g from trips
  where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if v_n <> 0 then
    raise exception 'prepnuti na hodiny nechalo % hlasu', v_n;
  end if;
  if v_g <> 'time' then
    raise exception 'update neprepnul granularitu: %', v_g;
  end if;
end $$;

-- ============================================================================
-- 4. Zámek přebírá novou délku, nebo mizí
-- ============================================================================
set local role postgres;

insert into trips (id, created_by, title, origin_label, origin_point,
                   date_window, duration_minutes, locked_range, status)
values (
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  '11111111-1111-1111-1111-111111111111',
  'Zamceny', 'Praha', st_point(14.42, 50.08)::geography,
  tstzrange('2026-09-01 00:00+02', '2026-10-01 00:00+02'), 1440,
  tstzrange('2026-09-05 00:00+02', '2026-09-06 00:00+02'), 'date_locked'
);
insert into trip_participants (trip_id, user_id, role) values
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   '11111111-1111-1111-1111-111111111111', 'organiser');

set local role authenticated;

select update_trip('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
                   '{"duration_minutes": 4320}'::jsonb);

do $$
declare t trips%rowtype;
begin
  select * into t from trips where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  if lower(t.locked_range) <> '2026-09-05 00:00+02'::timestamptz then
    raise exception 'zamek zmenil zacatek na %', lower(t.locked_range);
  end if;
  if upper(t.locked_range) <> '2026-09-08 00:00+02'::timestamptz then
    raise exception 'zamek neprevzal delku, konci %', upper(t.locked_range);
  end if;
  if t.status <> 'date_locked' then
    raise exception 'zamek zbytecne spadl, status %', t.status;
  end if;
end $$;

-- Okno posunuté pryč od zámku ho musí zrušit, ne nechat viset mimo.
select update_trip('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
                   '{"window_start": "2026-09-15 00:00+02"}'::jsonb);

do $$
declare t trips%rowtype;
begin
  select * into t from trips where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  if t.locked_range is not null then
    raise exception 'zamek mimo okno prezil: %', t.locked_range;
  end if;
  if t.status <> 'planning' then
    raise exception 'status zustal na % po zruseni zamku', t.status;
  end if;
end $$;

rollback;
