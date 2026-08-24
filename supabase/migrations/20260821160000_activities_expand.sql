-- ============================================================================
-- Víc aktivit a co si k nim sbalit.
--
-- Seznam vyrostl z 33 na 73 aktivit. Není to délka pro délku: „U vody" bez
-- rozdílu mezi koupáním, šnorchlem a lodí znamená, že seznam na balení vyjde
-- pro všechny tři stejný — a tím přestane být k něčemu. Čím přesnější je
-- aktivita, tím konkrétnější je to, co se z ní dá odvodit.
--
-- Pravidla se **přidávají**, nemažou. Předchozí seed začíná `delete from
-- packing_rules`, což je správné pro první naplnění a špatné pro doplněk.
-- Stejný postup má oddíl 4 migrace 20260804160000.
--
-- Klíče, ne věty: české texty skládá klient (lib/features/packing/domain).
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Profil počasí pro nové aktivity
-- ---------------------------------------------------------------------------
-- Bez tohohle by skialp spadl do 'general' a hodnotil se jako procházka:
-- teplý suchý den by dostal plus, přestože je to přesně ten den, kdy je
-- v horách břečka.
create or replace function _activity_profile(p_tags text[])
returns text language sql immutable as $$
  select case
    when p_tags && array['ski','cross_country','skating','snowboard',
                         'sledding','snowshoes','ski_touring','winter_hike']
                                                          then 'ski'
    when p_tags && array['lake','sea','paddling','swimming','snorkeling',
                         'diving','sailing','paddleboard'] then 'lake'
    when p_tags && array['hiking','viewpoint','climbing','cycling','mtb',
                         'via_ferrata','running','geocaching','mushrooming',
                         'waterfall']                     then 'hiking'
    when p_tags && array['camping','festival','fishing','horse_riding',
                         'picnic','bbq','stargazing']     then 'outdoor'
    when p_tags && array['city','market','shopping','zoo','theme_park',
                         'christmas_market','farmers_market','street_food',
                         'street_art','architecture','playground','farm',
                         'botanical']                     then 'city'
    when p_tags && array['museum','gallery','cafe','restaurant','wine',
                         'brewery','theatre','concert','caves','aquapark',
                         'wellness','spa_pool','cinema','church',
                         'technical_monument','planetarium','escape_room',
                         'bowling','board_games','distillery','degustation',
                         'guided_tour']                   then 'indoor'
    else 'general'
  end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Pravidla balení pro nové aktivity
-- ---------------------------------------------------------------------------
insert into packing_rules
  (item_key, category, priority, reason_key,
   activity_tags, transport, min_days, max_days,
   min_temp, max_temp, min_precip_prob, min_precip_mm, min_wind_gust,
   min_snow_cm, min_uv, needs_darkness, months)
values
-- ---- venku: kolo, ferraty, běh ---------------------------------------------
('pack.bike_helmet','safety',1,'reason.activity_cycling',
 '{mtb}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.repair_kit','gear',1,'reason.activity_cycling',
 '{mtb}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.grip_gloves','clothing',2,'reason.activity_cycling',
 '{mtb}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.ferrata_set','safety',1,'reason.activity_ferrata',
 '{via_ferrata}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.grip_gloves','clothing',1,'reason.activity_ferrata',
 '{via_ferrata}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.running_shoes','clothing',1,'reason.activity_running',
 '{running}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.offline_map','gear',2,'reason.activity_running',
 '{running}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
-- ---- venku: houby, ryby, kůň, hvězdy, piknik --------------------------------
('pack.mushroom_basket','gear',1,'reason.activity_mushrooming',
 '{mushrooming}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.tick_repellent','safety',1,'reason.tick_season',
 '{mushrooming,geocaching}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.offline_map','gear',1,'reason.no_signal_in_hills',
 '{geocaching}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.fishing_licence','documents',1,'reason.activity_fishing',
 '{fishing}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.fishing_rod','gear',1,'reason.activity_fishing',
 '{fishing}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.riding_helmet','safety',1,'reason.activity_riding',
 '{horse_riding}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.long_trousers','clothing',1,'reason.activity_riding',
 '{horse_riding}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.star_map','gear',2,'reason.activity_stargazing',
 '{stargazing}','{}',null,null, null,null,null,null,null,null,null,true,'{}'),
('pack.binoculars','gear',2,'reason.activity_stargazing',
 '{stargazing,waterfall}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.red_light','gear',1,'reason.activity_stargazing',
 '{stargazing}','{}',null,null, null,null,null,null,null,null,null,true,'{}'),
('pack.warm_layer','clothing',1,'reason.dark_early',
 '{stargazing}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.picnic_blanket','gear',1,'reason.activity_picnic',
 '{picnic}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.cutlery','food',2,'reason.activity_picnic',
 '{picnic,bbq}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.cooler_bag','food',2,'reason.activity_picnic',
 '{picnic,bbq}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
-- ---- voda -------------------------------------------------------------------
('pack.swimwear','clothing',1,'reason.activity_lake',
 '{swimming,paddleboard,spa_pool}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.towel','gear',1,'reason.activity_lake',
 '{swimming,spa_pool}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.swim_goggles','gear',3,'reason.activity_lake',
 '{swimming}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.swim_cap','gear',2,'reason.pool_rules',
 '{spa_pool}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.flip_flops','clothing',2,'reason.pool_rules',
 '{spa_pool}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.snorkel','gear',1,'reason.activity_sea',
 '{snorkeling}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.water_shoes','clothing',2,'reason.rocky_beaches',
 '{snorkeling,waterfall}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.diving_card','documents',1,'reason.activity_diving',
 '{diving}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.wetsuit','clothing',2,'reason.activity_diving',
 '{diving}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.boat_shoes','clothing',1,'reason.activity_sailing',
 '{sailing}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.seasickness','safety',2,'reason.activity_sailing',
 '{sailing}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.windbreaker','clothing',1,'reason.windy',
 '{sailing}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.dry_bag','gear',1,'reason.activity_paddleboard',
 '{paddleboard}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.waterproof_case','gear',1,'reason.activity_paddleboard',
 '{paddleboard,sailing,diving}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.quick_dry','clothing',2,'reason.activity_paddleboard',
 '{paddleboard,waterfall}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
-- ---- zima -------------------------------------------------------------------
('pack.ski_gloves','clothing',1,'reason.activity_ski',
 '{snowboard,ski_touring}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.goggles','gear',1,'reason.activity_ski',
 '{snowboard}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.ski_pass','documents',1,'reason.activity_ski',
 '{snowboard}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.sled','gear',1,'reason.activity_snow_fun',
 '{sledding}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.dry_socks','clothing',2,'reason.activity_snow_fun',
 '{sledding,snowshoes,winter_hike}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.snowshoes','gear',1,'reason.activity_snow_fun',
 '{snowshoes}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.poles','gear',2,'reason.activity_snow_fun',
 '{snowshoes,ski_touring,winter_hike}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.skins','gear',1,'reason.activity_ski_touring',
 '{ski_touring}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.avalanche_kit','safety',1,'reason.avalanche_terrain',
 '{ski_touring}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.headtorch','gear',1,'reason.dark_early',
 '{winter_hike,ski_touring}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.thermos','food',1,'reason.activity_winter',
 '{winter_hike,snowshoes,sledding}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.winter_boots','clothing',1,'reason.activity_winter',
 '{winter_hike,christmas_market}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.hand_warmers','clothing',3,'reason.freezing',
 '{christmas_market,winter_hike}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.mug_deposit','documents',2,'reason.markets_want_cash',
 '{christmas_market}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.cash','documents',1,'reason.markets_want_cash',
 '{christmas_market,farmers_market,street_food}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
-- ---- město a kultura ---------------------------------------------------------
('pack.comfy_shoes','clothing',1,'reason.long_day_on_feet',
 '{architecture,guided_tour,street_art,technical_monument}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.camera','gear',3,'reason.photos_worth_it',
 '{architecture,street_art,waterfall,botanical}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.light_layer','clothing',2,'reason.cold_interiors',
 '{church,technical_monument,planetarium}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.tickets','documents',1,'reason.booked_seat',
 '{cinema,guided_tour,planetarium}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.notebook','gear',3,'reason.activity_culture',
 '{guided_tour,degustation}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
-- ---- jídlo a pití ------------------------------------------------------------
('pack.tote_bag','gear',1,'reason.activity_shopping',
 '{farmers_market}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.cooler_bag','food',2,'reason.activity_food',
 '{farmers_market}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.wet_wipes','food',2,'reason.activity_food',
 '{street_food,bbq,picnic}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.designated_driver','safety',1,'reason.tasting_and_driving',
 '{distillery,degustation}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.water','food',1,'reason.tasting_and_driving',
 '{distillery,degustation}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.grill_tools','food',1,'reason.activity_bbq',
 '{bbq}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.charcoal','food',1,'reason.activity_bbq',
 '{bbq}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
-- ---- odpočinek a rodina ------------------------------------------------------
('pack.bathrobe','clothing',2,'reason.activity_wellness',
 '{spa_pool}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.kids_snack','food',1,'reason.activity_kids',
 '{playground,farm,zoo,botanical}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.kids_spare_clothes','clothing',1,'reason.activity_kids',
 '{playground,farm}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.wet_wipes','food',1,'reason.activity_kids',
 '{playground,farm}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}'),
('pack.board_game','gear',3,'reason.activity_indoor_game',
 '{board_games}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.bowling_socks','clothing',2,'reason.activity_indoor_game',
 '{bowling}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.comfy_shoes','clothing',2,'reason.long_day_on_feet',
 '{botanical,farm}','{}',null,null,
 null,null,null,null,null,null,null,false,'{}');
