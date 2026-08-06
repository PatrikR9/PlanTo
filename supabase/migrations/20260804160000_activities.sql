-- ============================================================================
-- Rozšíření slovníku aktivit z 8 na 27.
--
-- Nic se nepřejmenovává. Osm původních hodnot ('hiking', 'city', 'lake',
-- 'castle', 'museum', 'cafe', 'festival', 'viewpoint') zůstává beze změny,
-- takže žádný existující výlet nemění význam. Přibývají jen nové.
--
-- Největší z těch nových je 'sea'. Doteď všechno mokré spadalo pod 'lake',
-- jenže rybník u Třeboně a Jadran se liší dokladem, spálením, solí a osmi
-- hodinami cesty — a seznam na sbalení to musí poznat.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Profil počasí
-- ---------------------------------------------------------------------------
-- Pořadí je priorita: výlet označený zároveň jako lyže i kavárna je lyžovačka,
-- na které se dá zahřát, ne kavárna se sněhem.
--
-- Nový profil 'ski' obrací dvě věci, které jsou všude jinde penalizací: mráz
-- je v pořádku a sníh je důvod, proč tam jedete. Bez toho by lyžovačka
-- dostávala nejvyšší skóre za teplý suchý den, což je rada přesně naopak.
create or replace function _activity_profile(p_tags text[])
returns text language sql immutable as $$
  select case
    -- Zima vyhrává nad vším: teplo je tu problém, ne odměna.
    when p_tags && array['ski','cross_country','skating'] then 'ski'
    -- Voda dál chce teplo a klid. Moře k jezeru, ne k turistice.
    when p_tags && array['lake','sea','paddling']         then 'lake'
    when p_tags && array['hiking','viewpoint','climbing','cycling']
                                                          then 'hiking'
    when p_tags && array['camping','festival']            then 'outdoor'
    when p_tags && array['city','market','shopping','zoo','theme_park']
                                                          then 'city'
    -- Aquapark je uvnitř, i když je to voda. Wellness taky.
    when p_tags && array['museum','gallery','cafe','restaurant','wine',
                         'brewery','theatre','concert','caves','aquapark',
                         'wellness']                      then 'indoor'
    else 'general'
  end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Skóre počasí, teď i pro zimu
-- ---------------------------------------------------------------------------
-- Beze změny proti M6 kromě větve 'ski'. Vypsané celé, protože CREATE OR
-- REPLACE jinak neumí — a protože rozdělit skórovací funkci na kusy by
-- znamenalo, že "proč tenhle den dostal 62" se čte ze tří míst.
create or replace function _weather_score(
  p_profile      text,
  p_temp_max     numeric,
  p_apparent_max numeric,
  p_precip_mm    numeric,
  p_precip_prob  int,
  p_wind_gust    numeric,
  p_snow_cm      numeric,
  p_code         int,
  p_sunshine_s   int,
  p_daylight_s   int
)
returns int
language sql
immutable
as $$
  with felt as (
    select coalesce(p_apparent_max, p_temp_max) as t
  ),
  ideal as (
    select case p_profile
             when 'lake'   then 27.0
             when 'hiking' then 19.0
             when 'city'   then 21.0
             when 'indoor' then 18.0
             -- Minus dva je na svahu příjemný den. Nula znamená mokrý sníh.
             when 'ski'    then -2.0
             else 21.0
           end as target,
           case p_profile
             when 'lake'   then 3.5
             when 'hiking' then 1.4
             when 'indoor' then 0.4
             -- Mráz lyžaře netrápí zdaleka tak jako obleva.
             when 'ski'    then 0.5
             else 1.6
           end as cold_penalty,
           case p_profile
             when 'lake'   then 0.4
             when 'hiking' then 2.4
             when 'indoor' then 0.4
             -- Každý stupeň nad nulou bere sníh. Tohle je ta drahá strana.
             when 'ski'    then 2.8
             else 1.6
           end as heat_penalty,
           case p_profile when 'indoor' then 0.35 else 1.0 end as wet_weight,
           -- Sníh: všude překážka, na lyžích důvod cesty.
           case p_profile when 'ski' then -1 else 1 end as snow_sign
    from felt
  ),
  penalties as (
    select
      least(30.0, coalesce(p_precip_prob, 0) * 0.30) as p_prob,
      least(25.0, coalesce(p_precip_mm, 0) * 2.5)    as p_amount,
      case when p_code in (95, 96, 99) then 30.0 else 0.0 end as p_storm,
      greatest(0.0, least(20.0, (coalesce(p_wind_gust, 0) - 40) * 0.7)) as p_wind,
      -- U 'ski' je to bonus do 15 bodů, jinde penalizace do 20.
      (select case
                when snow_sign < 0
                  then -least(15.0, coalesce(p_snow_cm, 0) * 3.0)
                else least(20.0, coalesce(p_snow_cm, 0) * 4.0)
              end
       from ideal) as p_snow,
      case
        when p_sunshine_s is null or p_daylight_s is null or p_daylight_s = 0
          then 0.0
        else least(12.0, (1 - (p_sunshine_s::numeric / p_daylight_s)) * 12.0)
      end as p_grey,
      (select case
                when t < target then (target - t) * cold_penalty
                else (t - target) * heat_penalty
              end
       from felt, ideal) as p_temp,
      (select wet_weight from ideal) as wet
  )
  select case
    -- Beze změny a pořád to nejdůležitější v téhle funkci: chybějící
    -- předpověď je "nevíme", ne "krásně". Bez tohohle by byly všechny
    -- penalizace nulové a skóre by vyšlo 100.
    when p_temp_max is null and p_apparent_max is null and p_code is null
      then null
    else greatest(0, least(100, round(
        100
      - (p_prob + p_amount + p_storm) * wet
      - p_wind
      - p_snow
      - p_grey
      - least(35.0, p_temp)
    )))::int
  end
  from penalties;
$$;

comment on function _weather_score is
  'Deterministické skóre 0-100 podle profilu aktivity. Profil ski obrací mráz '
  'a sníh: obojí je tam, kde jinde stojí penalizace, důvod cesty.';

-- ---------------------------------------------------------------------------
-- 3. Jedna položka jednou, i když ji chce víc pravidel
-- ---------------------------------------------------------------------------
-- Se sedmadvaceti aktivitami se překryvy staly normálem: plavky chce moře,
-- aquapark i wellness, čelovku tma i kemp, opalovací krém UV i sníh. Výlet
-- označený dvěma z nich by je dostal dvakrát — a protože packing_checked je
-- klíčované item_key, odškrtnutí jedné by přeškrtlo obě a seznam by se choval
-- jako rozbitý.
--
-- Překryvy jsou ale správně: znamenají, že položka je potřeba z víc důvodů.
-- Nesmí se řešit v datech, kde by je někdo musel hlídat ručně, ale tady.
--
-- Vyhrává nejnutnější pravidlo, a při shodě to konkrétnější. "Prší v sobotu
-- odpoledne" je lepší důvod než "jedete k vodě", protože říká něco, co ten
-- člověk ještě neví.
create or replace function build_packing_list(p_trip uuid)
returns table (
  item_key   text,
  category   text,
  priority   int,
  reason_key text,
  checked    boolean,
  weather_based boolean
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  t        trips%rowtype;
  v_day    date;
  v_lat    numeric;
  v_lon    numeric;
  w        weather_daily%rowtype;
  v_month  int;
  v_dark   boolean := false;
begin
  select * into t from trips where id = p_trip;
  if not found or not is_trip_member(p_trip) then
    return;
  end if;

  if t.locked_range is not null then
    v_day := (lower(t.locked_range) at time zone t.timezone)::date;
  else
    select (c.starts_at at time zone t.timezone)::date into v_day
    from trip_candidates(p_trip, 1) c
    limit 1;
  end if;

  v_month := extract(month from coalesce(v_day, lower(t.date_window)::date));

  if v_day is not null then
    select lat, lon into v_lat, v_lon from _trip_weather_point(p_trip);
    select * into w from weather_daily
    where lat = v_lat and lon = v_lon and day = v_day;

    if w.sunset is not null and t.slot_minutes is not null
       and t.locked_range is not null then
      v_dark := upper(t.locked_range) > w.sunset - interval '30 minutes';
    end if;
  end if;

  return query
  with matched as (
    select distinct on (r.item_key)
      r.item_key   as k,
      r.category   as c,
      r.priority   as p,
      r.reason_key as rk,
      (r.min_temp is not null or r.max_temp is not null
        or r.min_precip_prob is not null or r.min_precip_mm is not null
        or r.min_wind_gust is not null or r.min_snow_cm is not null
        or r.min_uv is not null or r.needs_darkness) as wb
    from packing_rules r
    where
      (cardinality(r.activity_tags) = 0 or r.activity_tags && t.activity_tags)
      and (cardinality(r.transport) = 0 or t.transport = any(r.transport))
      and (r.min_days is null or coalesce(t.duration_days, 1) >= r.min_days)
      and (r.max_days is null or coalesce(t.duration_days, 1) <= r.max_days)
      and (cardinality(r.months) = 0 or v_month = any(r.months))
      and (r.min_temp        is null or w.apparent_max  >= r.min_temp)
      and (r.max_temp        is null or w.apparent_max  <= r.max_temp)
      and (r.min_precip_prob is null or w.precip_prob   >= r.min_precip_prob)
      and (r.min_precip_mm   is null or w.precip_mm     >= r.min_precip_mm)
      and (r.min_wind_gust   is null or w.wind_gust_kmh >= r.min_wind_gust)
      and (r.min_snow_cm     is null or w.snowfall_cm   >= r.min_snow_cm)
      and (r.min_uv          is null or w.uv_index      >= r.min_uv)
      and (not r.needs_darkness or v_dark)
    order by
      r.item_key,
      r.priority,
      -- Konkrétnost: kolik podmínek muselo sedět, aby pravidlo prošlo.
      -- Čím víc, tím víc ten důvod říká.
      (cardinality(r.activity_tags) + cardinality(r.transport)
        + cardinality(r.months)
        + (r.min_days is not null)::int + (r.max_days is not null)::int
        + (r.min_temp is not null)::int + (r.max_temp is not null)::int
        + (r.min_precip_prob is not null)::int
        + (r.min_precip_mm is not null)::int
        + (r.min_wind_gust is not null)::int
        + (r.min_snow_cm is not null)::int
        + (r.min_uv is not null)::int
        + r.needs_darkness::int) desc,
      -- Poslední úroveň jen proto, aby dvě stejně konkrétní pravidla
      -- nevracela pokaždé jiný důvod.
      r.reason_key
  )
  select
    m.k, m.c, m.p, m.rk,
    exists (
      select 1 from packing_checked pc
      where pc.trip_id = p_trip
        and pc.user_id = auth.uid()
        and pc.item_key = m.k
    ),
    m.wb
  from matched m
  order by m.p, m.c, m.k;
end;
$$;

grant execute on function build_packing_list(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Pravidla balení pro nové aktivity
-- ---------------------------------------------------------------------------
insert into packing_rules
  (item_key, category, priority, reason_key,
   activity_tags, transport, min_days, max_days,
   min_temp, max_temp, min_precip_prob, min_precip_mm, min_wind_gust,
   min_snow_cm, min_uv, needs_darkness, months)
values
-- ---- moře ------------------------------------------------------------------
-- Doklad je u moře jiná položka než u rybníka: přes hranice se jede vždycky,
-- a evropský průkaz pojištěnce je ta věc, kterou si nikdo nevzpomene vzít,
-- dokud ho nepotřebuje.
('pack.passport',      'documents', 1, 'reason.going_abroad',
 '{sea}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.ehic',          'documents', 1, 'reason.going_abroad',
 '{sea}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.beach_towel',   'gear',      1, 'reason.activity_sea',
 '{sea}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.swimwear',      'clothing',  1, 'reason.activity_sea',
 '{sea}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.water_shoes',   'clothing',  2, 'reason.rocky_beaches',
 '{sea}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.after_sun',     'safety',    2, 'reason.sea_sun_is_stronger',
 '{sea}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.sunscreen_high','safety',    1, 'reason.sea_sun_is_stronger',
 '{sea}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.snorkel',       'gear',      3, 'reason.activity_sea',
 '{sea}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- vodáctví --------------------------------------------------------------
('pack.dry_bag',       'gear',      1, 'reason.activity_paddling',
 '{paddling}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.quick_dry',     'clothing',  1, 'reason.activity_paddling',
 '{paddling}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.water_shoes',   'clothing',  1, 'reason.activity_paddling',
 '{paddling}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- aquapark --------------------------------------------------------------
('pack.swimwear',      'clothing',  1, 'reason.activity_aquapark',
 '{aquapark}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.flip_flops',    'clothing',  1, 'reason.activity_aquapark',
 '{aquapark}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.swim_cap',      'gear',      3, 'reason.activity_aquapark',
 '{aquapark}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- lyže a zima -----------------------------------------------------------
('pack.ski_pass',      'documents', 1, 'reason.activity_ski',
 '{ski}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.goggles',       'gear',      1, 'reason.activity_ski',
 '{ski,cross_country}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.helmet',        'safety',    1, 'reason.activity_ski',
 '{ski}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.thermal_layer', 'clothing',  1, 'reason.activity_winter',
 '{ski,cross_country,skating}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.ski_gloves',    'clothing',  1, 'reason.activity_winter',
 '{ski,cross_country,skating}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
-- Sníh odráží víc než písek a lidi to podceňují každý rok.
('pack.sunscreen',     'safety',    1, 'reason.snow_reflects_uv',
 '{ski,cross_country}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- kolo ------------------------------------------------------------------
('pack.bike_helmet',   'safety',    1, 'reason.activity_cycling',
 '{cycling}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.repair_kit',    'gear',      1, 'reason.activity_cycling',
 '{cycling}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.bike_lights',   'safety',    1, 'reason.back_after_sunset',
 '{cycling}','{}',null,null, null,null,null,null,null,null,null,true,'{}'),
('pack.bike_lock',     'gear',      2, 'reason.activity_cycling',
 '{cycling}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- lezení ----------------------------------------------------------------
('pack.climb_harness', 'gear',      1, 'reason.activity_climbing',
 '{climbing}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.climb_shoes',   'clothing',  1, 'reason.activity_climbing',
 '{climbing}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.chalk',         'gear',      2, 'reason.activity_climbing',
 '{climbing}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- kemp ------------------------------------------------------------------
('pack.sleeping_bag',  'gear',      1, 'reason.activity_camping',
 '{camping}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.sleeping_pad',  'gear',      1, 'reason.activity_camping',
 '{camping}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.headtorch',     'safety',    1, 'reason.activity_camping',
 '{camping}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.mosquito',      'safety',    2, 'reason.camping_summer',
 '{camping}','{}',null,null, null,null,null,null,null,null,null,false,'{5,6,7,8,9}'),

-- ---- jeskyně ---------------------------------------------------------------
-- V jeskyni je osm stupňů celý rok a lidi tam chodí v tričku, protože venku
-- je třicet.
('pack.warm_layer',    'clothing',  1, 'reason.caves_are_cold',
 '{caves}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.comfy_shoes',   'clothing',  1, 'reason.caves_are_wet',
 '{caves}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- koncert, divadlo, festival --------------------------------------------
('pack.tickets',       'documents', 1, 'reason.booked_seat',
 '{concert,theatre}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.earplugs',      'safety',    2, 'reason.activity_concert',
 '{concert}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.smart_clothes', 'clothing',  2, 'reason.activity_theatre',
 '{theatre}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- gastro ----------------------------------------------------------------
('pack.cash',          'documents', 1, 'reason.markets_want_cash',
 '{market,festival}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
-- Kdo řídí, ten nepije, a domluvit to předem je levnější než na místě.
('pack.designated_driver','documents', 1, 'reason.tasting_and_driving',
 '{wine,brewery}','{car}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.cooler_bag',    'gear',      3, 'reason.activity_wine',
 '{wine,brewery}','{car}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- wellness --------------------------------------------------------------
('pack.swimwear',      'clothing',  1, 'reason.activity_wellness',
 '{wellness}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.flip_flops',    'clothing',  1, 'reason.activity_wellness',
 '{wellness}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.bathrobe',      'clothing',  3, 'reason.activity_wellness',
 '{wellness}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- zoo a zábavní park ----------------------------------------------------
('pack.comfy_shoes',   'clothing',  1, 'reason.long_day_on_feet',
 '{zoo,theme_park}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.snack',         'food',      2, 'reason.overpriced_inside',
 '{zoo,theme_park}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- nákupy ----------------------------------------------------------------
('pack.tote_bag',      'gear',      2, 'reason.activity_shopping',
 '{shopping}','{}',null,null, null,null,null,null,null,null,null,false,'{}');
