-- Rozpad nákladů.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/costs_test.sql
--
-- Testuje se hlavně to, co se dá snadno rozbít tiše: že se doprava nezapočítá
-- dvakrát, že jídlo roste s délkou, a že vícedenní výlet přizná chybějící
-- nocleh místo aby ukázal součet, který ho vynechá. Ta poslední je z nich
-- nejdražší — čtyřtisícový rozdíl v odhadu je přesně to, po čem lidem přestane
-- být jedno, co jim aplikace tvrdí.
--
-- Běží jako `authenticated`, ne jako postgres. Chyba v grantech je jinak
-- neviditelná, jak ukázalo busy_intervals.

begin;
set local role postgres;

insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at,
                        created_at, updated_at)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'a@test.cz', now(), now(), now()),
  ('44444444-4444-4444-4444-444444444444', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'd@test.cz', now(), now(), now());

-- `on conflict` kvůli triggeru `on_auth_user_created`: vložení do
-- auth.users už profil založilo, takže tenhle insert do něj jen
-- doplní jméno. Bez toho test spadne na profiles_pkey dřív, než se
-- vůbec dostane k tomu, co má ověřit.
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'Anna'),
  ('44444444-4444-4444-4444-444444444444', 'Dan')
on conflict (id) do update set display_name = excluded.display_name;

-- Praha → Český Krumlov, jeden den, veřejnou dopravou.
insert into trips (id, created_by, title, origin_label, origin_point,
                   destination_free, destination_point,
                   date_window, duration_days, transport)
values (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '11111111-1111-1111-1111-111111111111',
  'Jednodenni', 'Praha', st_point(14.42, 50.08)::geography,
  'Cesky Krumlov', st_point(14.3175, 48.8127)::geography,
  tstzrange('2026-09-11 00:00+02', '2026-09-15 00:00+02'), 1, 'public'
);

-- Stejná cesta, ale na tři dny.
insert into trips (id, created_by, title, origin_label, origin_point,
                   destination_free, destination_point,
                   date_window, duration_days, transport)
values (
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  '11111111-1111-1111-1111-111111111111',
  'Tridenni', 'Praha', st_point(14.42, 50.08)::geography,
  'Cesky Krumlov', st_point(14.3175, 48.8127)::geography,
  tstzrange('2026-09-11 00:00+02', '2026-09-20 00:00+02'), 3, 'public'
);

-- A jeden bez cíle.
insert into trips (id, created_by, title, origin_label, origin_point,
                   date_window, duration_days, transport)
values (
  'cccccccc-cccc-cccc-cccc-cccccccccccc',
  '11111111-1111-1111-1111-111111111111',
  'Bez cile', 'Praha', st_point(14.42, 50.08)::geography,
  tstzrange('2026-09-11 00:00+02', '2026-09-15 00:00+02'), 1, 'public'
);

insert into trip_participants (trip_id, user_id, role) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '11111111-1111-1111-1111-111111111111', 'organiser'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   '11111111-1111-1111-1111-111111111111', 'organiser'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc',
   '11111111-1111-1111-1111-111111111111', 'organiser');

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- 1. Jednodenní: doprava + jídlo + rezerva, žádný nocleh --------------------
do $$
declare
  v_kinds text[];
  v_transport int;
begin
  select array_agg(kind order by kind) into v_kinds
  from estimate_trip_cost('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

  if v_kinds is distinct from array['buffer','food','transport'] then
    raise exception 'jednodenni vylet ma polozky %', v_kinds;
  end if;

  -- Doprava se smí objevit právě jednou. Kdyby se sečetly obě možnosti,
  -- účtovala by se cesta dvakrát; u 'public' navíc auto vůbec nemá vzniknout.
  select count(*) into v_transport
  from estimate_trip_cost('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  where kind = 'transport';
  if v_transport <> 1 then
    raise exception 'doprava je na % radcich', v_transport;
  end if;
end $$;

-- 2. Jídlo roste s délkou -----------------------------------------------------
do $$
declare
  v_one numeric;
  v_three numeric;
begin
  select min_czk into v_one from estimate_trip_cost(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') where kind = 'food';
  select min_czk into v_three from estimate_trip_cost(
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') where kind = 'food';

  if v_three <> v_one * 3 then
    raise exception 'jidlo neskaluje: 1 den = %, 3 dny = %', v_one, v_three;
  end if;
end $$;

-- 3. Vícedenní přizná nocleh, který neumí -------------------------------------
-- Nejdůležitější tvrzení v souboru. Řádek musí existovat a musí být BEZ čísel:
-- nula by znamenala "nocleh zdarma", což je jiné tvrzení než "nevíme".
do $$
declare
  v_min numeric;
  v_max numeric;
  v_conf text;
  v_n int;
begin
  select count(*) into v_n
  from estimate_trip_cost('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')
  where kind = 'accommodation';
  if v_n <> 1 then
    raise exception 'tridenni vylet nepriznal nocleh';
  end if;

  select min_czk, max_czk, confidence into v_min, v_max, v_conf
  from estimate_trip_cost('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')
  where kind = 'accommodation';

  if v_min is not null or v_max is not null then
    raise exception 'nocleh ma cislo (%–%), ma byt bez nej', v_min, v_max;
  end if;
  if v_conf <> 'unknown' then
    raise exception 'nocleh ma confidence %, ma mit unknown', v_conf;
  end if;
end $$;

-- 4. Rozpětí dává smysl -------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select * from estimate_trip_cost('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  loop
    if r.min_czk is not null and r.min_czk > r.max_czk then
      raise exception 'polozka % ma min > max (% > %)',
        r.kind, r.min_czk, r.max_czk;
    end if;
    if r.min_czk is not null and r.min_czk < 0 then
      raise exception 'polozka % je zaporna', r.kind;
    end if;
  end loop;
end $$;

-- 5. Bez cíle mlčí ------------------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n
  from estimate_trip_cost('cccccccc-cccc-cccc-cccc-cccccccccccc');
  if v_n <> 0 then
    raise exception 'vylet bez cile vratil % radku', v_n;
  end if;
end $$;

-- 6. Nečlen nedostane nic -----------------------------------------------------
set local request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';

do $$
declare v_n int;
begin
  select count(*) into v_n
  from estimate_trip_cost('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  if v_n <> 0 then
    raise exception 'necten videl rozpocet ciziho vyletu';
  end if;
end $$;

rollback;
