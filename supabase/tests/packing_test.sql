-- Pravidlový generátor seznamu na sbalení.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/packing_test.sql
--
-- Testuje se to, co dělá seznam důvěryhodným: že chybějící předpověď nikdy
-- nevypadá jako hezky, že se pravidla na aktivity neuplatní na výlet, který ta
-- aktivita nezajímá, a že odškrtnutí jednoho člověka nezmizí položku ostatním.
--
-- Běží jako `authenticated`.

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
  ('22222222-2222-2222-2222-222222222222', 'Bohus');

-- Jednodenní turistika autem, cíl nastavený, žádná předpověď v cache.
insert into trips (id, created_by, title, origin_label, origin_point,
                   destination_free, destination_point,
                   date_window, duration_days, transport, activity_tags,
                   timezone)
values (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '11111111-1111-1111-1111-111111111111',
  'Turistika', 'Praha', st_point(14.42, 50.08)::geography,
  'Bezdez', st_point(14.7203, 50.5386)::geography,
  tstzrange('2026-09-11 00:00+02', '2026-09-15 00:00+02'), 1, 'car',
  '{hiking}', 'Europe/Prague'
);

insert into trip_participants (trip_id, user_id, role) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '11111111-1111-1111-1111-111111111111', 'organiser'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '22222222-2222-2222-2222-222222222222', 'member');

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- 1. Bez předpovědi se pravidla na počasí NEUPLATNÍ -------------------------
-- Nejdůležitější tvrzení v souboru a stejné rozhodnutí jako u _weather_score,
-- který vrací null místo 100. Kdyby se chybějící data četla jako "nula srážek,
-- nula větru, nula sněhu", seznam by u každého neznámého termínu sebejistě
-- tvrdil "hezky, nic navíc si neber" — a to je jediná rada, kterou tenhle
-- seznam nesmí dát omylem.
do $$
declare v_n int;
begin
  select count(*) into v_n
  from build_packing_list('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  where weather_based;
  if v_n <> 0 then
    raise exception 'bez predpovedi proslo % pravidel na pocasi', v_n;
  end if;
end $$;

-- 2. Základ a aktivita projdou vždycky ---------------------------------------
do $$
declare v_keys text[];
begin
  select array_agg(item_key) into v_keys
  from build_packing_list('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

  if not (v_keys @> array['pack.id','pack.water']) then
    raise exception 'chybi zaklad: %', v_keys;
  end if;
  if not (v_keys @> array['pack.hiking_boots','pack.offline_map']) then
    raise exception 'chybi turisticka pravidla: %', v_keys;
  end if;
  -- Auto ano, veřejná doprava ne — trip má transport = 'car'.
  if not (v_keys @> array['pack.vignette']) then
    raise exception 'chybi pravidla pro auto';
  end if;
  if v_keys @> array['pack.ticket_app'] then
    raise exception 'pravidlo pro verejnou dopravu proslo u auta';
  end if;
  -- Jednodenní výlet nemá co dělat se zubním kartáčkem.
  if v_keys @> array['pack.toothbrush'] then
    raise exception 'pravidlo pro nocleh proslo u jednodenniho vyletu';
  end if;
  -- A plavky se na turistiku nebalí.
  if v_keys @> array['pack.swimwear'] then
    raise exception 'pravidlo pro vodu proslo u turistiky';
  end if;
end $$;

-- 3. S předpovědí přibudou pravidla na počasí ---------------------------------
set local role postgres;

-- Zamknout termín, aby se vědělo, na který den se balí.
update trips set locked_range =
  tstzrange('2026-09-12 08:00+02', '2026-09-12 18:00+02'),
  slot_minutes = 600
where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

-- Deštivý, studený a větrný den na mřížce cíle (zaokrouhleno na 0,1°).
insert into weather_daily (lat, lon, day, weather_code, temp_max, temp_min,
                           apparent_max, precip_mm, precip_prob, wind_gust_kmh,
                           snowfall_cm, uv_index, sunrise, sunset,
                           daylight_seconds)
values (50.5, 14.7, '2026-09-12', 63, 11.0, 6.0, 9.0, 14.0, 85, 55.0,
        0.0, 2.0, '2026-09-12 06:30+02', '2026-09-12 19:40+02', 47400);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare v_keys text[];
begin
  select array_agg(item_key) into v_keys
  from build_packing_list('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

  -- 85 % déšť, 14 mm, 9 °C pocitově, nárazy 55 km/h.
  if not (v_keys @> array['pack.rain_jacket','pack.rain_trousers',
                          'pack.warm_layer','pack.windbreaker']) then
    raise exception 'chybi pravidla na pocasi: %', v_keys;
  end if;
  -- UV 2 je málo na krém a sníh nepadá.
  if v_keys && array['pack.sunscreen','pack.winter_boots'] then
    raise exception 'proslo pravidlo, ktere nemelo: %', v_keys;
  end if;
  -- Návrat v 18:00, západ v 19:40 — čelovka ne.
  if v_keys @> array['pack.headtorch'] then
    raise exception 'celovka proslo pri navratu pred zapadem';
  end if;
end $$;

-- 4. Návrat po setmění ---------------------------------------------------------
set local role postgres;
update trips set locked_range =
  tstzrange('2026-09-12 08:00+02', '2026-09-12 19:30+02')
where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare v_n int;
begin
  select count(*) into v_n
  from build_packing_list('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  where item_key = 'pack.headtorch';
  -- 19:30 je uvnitř půlhodinové rezervy před západem v 19:40. Soumrak není
  -- okamžik a sestup po tmě bez světla je jediná položka na tomhle seznamu,
  -- jejíž zapomenutí končí voláním horské služby.
  if v_n <> 1 then
    raise exception 'celovka nechybi ani neni pri navratu za sera';
  end if;
end $$;

-- 5. Odškrtnutí je vlastní, ne skupinové --------------------------------------
select set_packing_checked(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'pack.water', true);

do $$
declare v_checked boolean;
begin
  select checked into v_checked
  from build_packing_list('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  where item_key = 'pack.water';
  if not v_checked then
    raise exception 'odskrtnuti se neprojevilo';
  end if;
end $$;

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

do $$
declare v_checked boolean;
begin
  select checked into v_checked
  from build_packing_list('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  where item_key = 'pack.water';
  if v_checked then
    raise exception 'Anna odskrtla vodu i Bohusovi';
  end if;
end $$;

-- 6. Překryv pravidel dá položku jednou ---------------------------------------
-- Plavky chce moře, aquapark i wellness. Výlet označený všemi třemi je zcela
-- běžný (lázně u moře s bazénem) a musí dostat plavky jednou — packing_checked
-- je klíčované item_key, takže dva řádky se stejným klíčem znamenají seznam,
-- kde odškrtnutí jednoho přeškrtne oba.
set local role postgres;

insert into trips (id, created_by, title, origin_label, origin_point,
                   destination_free, destination_point,
                   date_window, duration_days, transport, activity_tags,
                   timezone)
values (
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  '11111111-1111-1111-1111-111111111111',
  'More', 'Praha', st_point(14.42, 50.08)::geography,
  'Jadran', st_point(14.4400, 44.8700)::geography,
  tstzrange('2026-07-11 00:00+02', '2026-07-25 00:00+02'), 7, 'car',
  '{sea,aquapark,wellness}', 'Europe/Prague'
);
insert into trip_participants (trip_id, user_id, role) values
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   '11111111-1111-1111-1111-111111111111', 'organiser');

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare
  v_dupes text[];
  v_keys  text[];
begin
  select array_agg(item_key) into v_dupes
  from (
    select item_key from build_packing_list(
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')
    group by item_key having count(*) > 1
  ) d;
  if v_dupes is not null then
    raise exception 'polozky dvakrat: %', v_dupes;
  end if;

  select array_agg(item_key) into v_keys
  from build_packing_list('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

  -- To, kvůli čemu se celý slovník rozšiřoval.
  if not (v_keys @> array['pack.swimwear','pack.passport','pack.ehic',
                          'pack.beach_towel']) then
    raise exception 'more nedostalo sve polozky: %', v_keys;
  end if;
  -- Sedmidenní výlet = nocleh a převlečení.
  if not (v_keys @> array['pack.toothbrush','pack.laundry_bag']) then
    raise exception 'tydenni vylet nedostal pravidla na noclehy';
  end if;
  -- A pořád žádná turistika ani lyže.
  if v_keys && array['pack.hiking_boots','pack.ski_pass'] then
    raise exception 'proslo pravidlo z jine aktivity: %', v_keys;
  end if;
end $$;

-- 7. Profil počasí: zima obrací mráz i sníh -----------------------------------
-- Jako postgres: EXECUTE na _weather_score i _activity_profile je odebraný
-- public (M6), protože je nikdo zvenčí volat nemá — jsou to vnitřnosti
-- skórování, ne API. Volat je jako `authenticated` by tady netestovalo
-- skórování, jen ten revoke.
set local role postgres;

do $$
declare
  v_ski  int;
  v_hike int;
begin
  if _activity_profile('{ski}') <> 'ski' then
    raise exception 'lyze nedostaly svuj profil';
  end if;
  if _activity_profile('{sea}') <> 'lake' then
    raise exception 'more ma jit na vodni profil';
  end if;

  -- Mrazivý den se sněhem: pro lyže dobrý, pro turistiku ne.
  v_ski  := _weather_score('ski',    -3, -5, 0, 10, 15, 12, 71, 14000, 30000);
  v_hike := _weather_score('hiking', -3, -5, 0, 10, 15, 12, 71, 14000, 30000);
  if v_ski <= v_hike then
    raise exception 'zimni den: lyze % nejsou nad turistikou %', v_ski, v_hike;
  end if;

  -- A chybějící předpověď je pořád null, i pro nový profil.
  if _weather_score('ski', null, null, null, null, null, null, null,
                    null, null) is not null then
    raise exception 'bez predpovedi vratil profil ski cislo';
  end if;
end $$;

rollback;
