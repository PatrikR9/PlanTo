-- Zápisová cesta do busy_intervals, testovaná jako role `authenticated`.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/busy_write_test.sql
--
-- PROČ TENHLE SOUBOR EXISTUJE
--
-- Klient nahrával kalendář přímo přes PostgREST a padalo to na
-- "permission denied for table busy_intervals". Nebyla to chyba v RLS: SELECT
-- na té tabulce je odebraný záměrně, a Postgres chce SELECT na každý sloupec,
-- který čte WHERE u DELETE. Tabulka, ze které nikdo nesmí číst, tedy nejde ani
-- filtrovaně mazat — a "smaž moje staré bloky" je první krok každého nahrání.
--
-- Chyba přežila, protože všechny ostatní testy běží jako postgres, kterému
-- práva nikdo nekontroluje. Tenhle se přepne na `authenticated` a drží obojí
-- najednou: že se číst nedá, a že zapsat jde.

begin;
set local role postgres;

insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at,
                        created_at, updated_at)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'a@test.cz', now(), now(), now()),
  ('44444444-4444-4444-4444-444444444444', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'd@test.cz', now(), now(), now());

insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'Anna'),
  ('44444444-4444-4444-4444-444444444444', 'Dan');

insert into trips (id, created_by, title, origin_label, origin_point,
                   date_window, duration_days)
values (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '11111111-1111-1111-1111-111111111111',
  'Test', 'Praha', st_point(14.42, 50.08)::geography,
  tstzrange('2026-09-11 00:00+02', '2026-09-15 00:00+02'), 1
);

insert into trip_participants (trip_id, user_id, role) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '11111111-1111-1111-1111-111111111111', 'organiser');
-- Dan je přihlášený, ale do výletu nepatří.

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- 1. Slib soukromí: ani vlastní řádky se přímo přečíst nedají ------------------
do $$
declare v_n int;
begin
  begin
    select count(*) into v_n from busy_intervals;
    raise exception 'REGRESE: authenticated smi SELECT na busy_intervals';
  exception
    when insufficient_privilege then null;   -- přesně tohle chceme
  end;
end $$;

-- 2. Nahrání ze zařízení ------------------------------------------------------
select set_device_busy(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '[{"start":"2026-09-12T06:00:00Z","end":"2026-09-12T18:00:00Z","all_day":false}]'::jsonb
);

do $$
declare
  v_blocks int;
  v_shared boolean;
begin
  select count(*) into v_blocks
  from my_busy_blocks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  if v_blocks <> 1 then
    raise exception 'ocekaval jsem 1 blok, mam %', v_blocks;
  end if;

  select calendar_shared into v_shared from trip_participants
  where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    and user_id = '11111111-1111-1111-1111-111111111111';
  if not v_shared then
    raise exception 'calendar_shared se nenastavilo ve stejne transakci';
  end if;
end $$;

-- 3. Nahradit, ne přidat ------------------------------------------------------
-- Druhé volání s jedním blokem musí skončit jedním blokem, ne dvěma. Bez toho
-- by každá re-synchronizace zdvojila zabraný čas a skupina by postupně přišla
-- o všechny termíny.
select set_device_busy(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '[{"start":"2026-09-13T06:00:00Z","end":"2026-09-13T10:00:00Z","all_day":false}]'::jsonb
);

do $$
declare v_n int;
begin
  select count(*) into v_n
  from my_busy_blocks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  if v_n <> 1 then
    raise exception 'nahrazeni nefunguje: % bloku', v_n;
  end if;
end $$;

-- 4. Ořez na okno výletu ------------------------------------------------------
-- Klient o verzi pozadu pošle blok mimo okno. Uložit se nesmí nic, co solver
-- stejně nikdy nepřečte.
select set_device_busy(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '[{"start":"2026-11-01T06:00:00Z","end":"2026-11-01T10:00:00Z","all_day":false},
    {"start":"2026-09-14T06:00:00Z","end":"2026-09-14T10:00:00Z","all_day":false}]'::jsonb
);

do $$
declare v_n int;
begin
  select count(*) into v_n
  from my_busy_blocks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  if v_n <> 1 then
    raise exception 'blok mimo okno se ulozil: % bloku', v_n;
  end if;
end $$;

-- 5. Prázdné pole je odpověď, ne chyba ----------------------------------------
-- "V kalendáři mi nic nebrání" je platný výsledek a musí člověka označit za
-- toho, kdo dostupnost sdílel — jinak na něj skupina čeká navždy.
select set_device_busy('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '[]'::jsonb);

do $$
declare
  v_n int;
  v_shared boolean;
begin
  select count(*) into v_n
  from my_busy_blocks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  select calendar_shared into v_shared from trip_participants
  where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    and user_id = '11111111-1111-1111-1111-111111111111';
  if v_n <> 0 or not v_shared then
    raise exception 'prazdne pole: % bloku, shared=%', v_n, v_shared;
  end if;
end $$;

-- 6. Odpojení maže hned -------------------------------------------------------
select set_device_busy(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '[{"start":"2026-09-12T06:00:00Z","end":"2026-09-12T18:00:00Z"}]'::jsonb
);
select clear_my_busy('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

do $$
declare
  v_n int;
  v_shared boolean;
begin
  select count(*) into v_n
  from my_busy_blocks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  select calendar_shared into v_shared from trip_participants
  where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    and user_id = '11111111-1111-1111-1111-111111111111';
  if v_n <> 0 or v_shared then
    raise exception 'odpojeni nedotahlo: % bloku, shared=%', v_n, v_shared;
  end if;
end $$;

-- 7. Nečlen neprojde ----------------------------------------------------------
-- security definer obchází RLS z definice, takže tohle je jediná obrana.
set local request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';

do $$
begin
  begin
    perform set_device_busy(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      '[{"start":"2026-09-12T06:00:00Z","end":"2026-09-12T18:00:00Z"}]'::jsonb
    );
    raise exception 'REGRESE: necten zapsal do ciziho vyletu';
  exception
    when insufficient_privilege then null;
  end;
end $$;

rollback;
