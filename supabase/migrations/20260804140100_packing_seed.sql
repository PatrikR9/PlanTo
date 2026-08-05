-- ============================================================================
-- Pravidla balení — obsah, ne schéma.
--
-- Vlastní migrace schválně: pravidla se budou doplňovat mnohem častěji než
-- tabulka, ve které leží, a přeseedování nemá mít možnost sáhnout na strukturu.
--
-- Rozsah je záměrně střední Evropa a jednodenní až třídenní výlety vlakem,
-- autem a po svých. Pravidlo, které nepokrývá nic z toho, sem nepatří: seznam,
-- ve kterém je půlka položek irelevantních, se přestane číst celý.
--
-- Klíče, ne věty. České texty skládá klient (lib/features/packing/domain).
-- ============================================================================

delete from packing_rules;

insert into packing_rules
  (item_key, category, priority, reason_key,
   activity_tags, transport, min_days, max_days,
   min_temp, max_temp, min_precip_prob, min_precip_mm, min_wind_gust,
   min_snow_cm, min_uv, needs_darkness, months)
values
-- ---- vždycky ---------------------------------------------------------------
('pack.id',            'documents', 1, 'reason.always',
 '{}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.phone_charger', 'gear',      1, 'reason.always',
 '{}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.water',         'food',      1, 'reason.always',
 '{}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
-- Hospody a chaty mimo město berou karty čím dál víc, ale ne všechny, a
-- zjistit to na místě je pozdě.
('pack.cash',          'documents', 2, 'reason.cash_outside_city',
 '{}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.snack',         'food',      2, 'reason.always',
 '{}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.powerbank',     'gear',      2, 'reason.navigation_drains_battery',
 '{}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- déšť ------------------------------------------------------------------
('pack.rain_jacket',   'clothing',  1, 'reason.rain_expected',
 '{}','{}',null,null, null,null,40,null,null,null,null,false,'{}'),
('pack.umbrella',      'gear',      3, 'reason.rain_expected',
 '{city,museum,cafe}','{}',null,null, null,null,50,null,null,null,null,false,'{}'),
-- Pláštěnka stačí na přeháňku; na deset milimetrů za den nestačí.
('pack.rain_trousers', 'clothing',  2, 'reason.heavy_rain',
 '{hiking,viewpoint}','{}',null,null, null,null,null,10,null,null,null,false,'{}'),
('pack.dry_bag',       'gear',      3, 'reason.heavy_rain',
 '{hiking,lake}','{}',null,null, null,null,null,10,null,null,null,false,'{}'),

-- ---- zima ------------------------------------------------------------------
('pack.warm_layer',    'clothing',  1, 'reason.cold_day',
 '{}','{}',null,null, null,12,null,null,null,null,null,false,'{}'),
('pack.hat_gloves',    'clothing',  1, 'reason.freezing',
 '{}','{}',null,null, null,3,null,null,null,null,null,false,'{}'),
('pack.thermos',       'food',      2, 'reason.freezing',
 '{}','{}',null,null, null,5,null,null,null,null,null,false,'{}'),
('pack.winter_boots',  'clothing',  1, 'reason.snow',
 '{}','{}',null,null, null,null,null,null,null,1,null,false,'{}'),

-- ---- horko a slunce --------------------------------------------------------
('pack.sunscreen',     'safety',    1, 'reason.strong_sun',
 '{}','{}',null,null, null,null,null,null,null,null,5,false,'{}'),
('pack.sunglasses',    'gear',      2, 'reason.strong_sun',
 '{}','{}',null,null, null,null,null,null,null,null,4,false,'{}'),
('pack.sun_hat',       'clothing',  2, 'reason.strong_sun',
 '{hiking,lake,viewpoint,festival}','{}',null,null,
 null,null,null,null,null,null,5,false,'{}'),
('pack.extra_water',   'food',      1, 'reason.hot_day',
 '{}','{}',null,null, 26,null,null,null,null,null,null,false,'{}'),

-- ---- vítr ------------------------------------------------------------------
('pack.windbreaker',   'clothing',  2, 'reason.windy',
 '{hiking,viewpoint,lake}','{}',null,null,
 null,null,null,null,45,null,null,false,'{}'),

-- ---- tma -------------------------------------------------------------------
-- Nejdůležitější pravidlo v souboru. Sestup za tmy bez světla je jediná
-- položka tady, jejíž zapomenutí končí voláním horské služby.
('pack.headtorch',     'safety',    1, 'reason.back_after_sunset',
 '{}','{}',null,null, null,null,null,null,null,null,null,true,'{}'),

-- ---- turistika -------------------------------------------------------------
('pack.hiking_boots',  'clothing',  1, 'reason.activity_hiking',
 '{hiking}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.blister_plasters','safety',   1, 'reason.activity_hiking',
 '{hiking}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.offline_map',   'gear',      1, 'reason.no_signal_in_hills',
 '{hiking,viewpoint}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.first_aid',     'safety',    2, 'reason.activity_hiking',
 '{hiking}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.poles',         'gear',      3, 'reason.activity_hiking',
 '{hiking}','{}',2,null, null,null,null,null,null,null,null,false,'{}'),
-- Klíšťata v Česku od dubna do října, a v nížinách i mimo les.
('pack.tick_repellent','safety',    2, 'reason.tick_season',
 '{hiking,lake,viewpoint}','{}',null,null,
 null,null,null,null,null,null,null,false,'{4,5,6,7,8,9,10}'),

-- ---- voda ------------------------------------------------------------------
('pack.swimwear',      'clothing',  1, 'reason.activity_lake',
 '{lake}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.towel',         'gear',      1, 'reason.activity_lake',
 '{lake}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.flip_flops',    'clothing',  3, 'reason.activity_lake',
 '{lake}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- město, hrady, muzea ---------------------------------------------------
('pack.comfy_shoes',   'clothing',  2, 'reason.activity_city',
 '{city,museum,castle}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
-- Hradní interiéry mají svoje mikroklima a nezajímá je, že venku je třicet.
('pack.light_layer',   'clothing',  3, 'reason.cold_interiors',
 '{castle,museum}','{}',null,null, 22,null,null,null,null,null,null,false,'{}'),

-- ---- festival --------------------------------------------------------------
('pack.earplugs',      'safety',    2, 'reason.activity_festival',
 '{festival}','{}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.poncho',        'clothing',  2, 'reason.activity_festival',
 '{festival}','{}',null,null, null,null,30,null,null,null,null,false,'{}'),

-- ---- auto ------------------------------------------------------------------
('pack.driving_licence','documents',1, 'reason.going_by_car',
 '{}','{car}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.vignette',      'documents', 1, 'reason.motorway_vignette',
 '{}','{car}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.phone_holder',  'gear',      3, 'reason.going_by_car',
 '{}','{car}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- veřejná doprava -------------------------------------------------------
('pack.ticket_app',    'documents', 1, 'reason.going_by_public',
 '{}','{public}',null,null, null,null,null,null,null,null,null,false,'{}'),
('pack.headphones',    'gear',      3, 'reason.going_by_public',
 '{}','{public}',null,null, null,null,null,null,null,null,null,false,'{}'),

-- ---- přes noc --------------------------------------------------------------
('pack.toothbrush',    'gear',      1, 'reason.overnight',
 '{}','{}',2,null, null,null,null,null,null,null,null,false,'{}'),
('pack.change_clothes','clothing',  1, 'reason.overnight',
 '{}','{}',2,null, null,null,null,null,null,null,null,false,'{}'),
('pack.dry_socks',     'clothing',  1, 'reason.overnight_hiking',
 '{hiking}','{}',2,null, null,null,null,null,null,null,null,false,'{}'),
('pack.deodorant',     'gear',      2, 'reason.overnight',
 '{}','{}',2,null, null,null,null,null,null,null,null,false,'{}'),
('pack.medication',    'safety',    1, 'reason.overnight',
 '{}','{}',2,null, null,null,null,null,null,null,null,false,'{}'),
('pack.laundry_bag',   'gear',      3, 'reason.longer_trip',
 '{}','{}',3,null, null,null,null,null,null,null,null,false,'{}');
