-- ============================================================================
-- M7 — skutečná databáze zastávek.
--
-- Do téhle chvíle byl výchozí bod výletu jedna z dvaceti ručně napsaných měst
-- a cíl jedna z dvaadvaceti ručně napsaných destinací. Obojí byl stopgap a
-- obojí tady končí.
--
-- CO JE ODKUD (ověřeno 8. srpna 2026, plný zápis v TRANSIT_DATA.md)
--
--   CIS JŘ / JDF   Ministerstvo dopravy, portal.cisjr.cz. V NKOD vedeno jako
--                  „není autorským dílem, není chráněno zvláštním právem
--                  pořizovatele databáze" — tedy volné dílo. Komerční užití
--                  bez podmínek. Všechny linkové autobusy v ČR.
--   CZPTT          Jízdní řády vlaků, konverze do GTFS, CC0-1.0.
--   PID            data.pid.cz, CC BY 4.0. Praha + Střední Čechy včetně
--                  metra, tramvají, trolejbusů, přívozů a lanovky. Jediný
--                  zdroj, který nese okres, obec a IDOS názvy — proto je
--                  autoritativní pro svoje území.
--   regionální IDS ODIS, IDS JMK, IDZK, PMDP, DPMO… licence per feed.
--
-- Attribution není volitelná u CC BY zdrojů. Sloupec attribution v
-- feed_licences je to, co obrazovka „O aplikaci" vypisuje; feed bez vyplněné
-- licence se importem neprojde.
--
-- CO SEM NEPATŘÍ
--   OpenStreetMap — ODbL, share-alike, past už jednou zapsaná v registru.
--   Ručně psané seznamy — celý smysl téhle migrace je jejich odstranění.
--
-- Apply with: supabase db push
-- ============================================================================

-- pg_trgm nese fuzzy hledání a zároveň zrychluje LIKE '%x%'. unaccent
-- schválně NEPOUŽÍVÁME: unaccent() je STABLE, ne IMMUTABLE, takže se nedá
-- použít v generovaném sloupci ani v indexu, a obcházet to dvouargumentovou
-- formou znamená natvrdo zapsat schéma, do kterého Supabase extension zrovna
-- nainstaloval. pt_norm() níž dělá totéž deterministicky a bez závislosti.
create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------------
-- 1. Normalizace
-- ---------------------------------------------------------------------------
-- Jediné místo, kde se rozhoduje, že „Černý Most", „cerny most" a
-- „CERNY  MOST" jsou totéž. Používá ho import, generovaný sloupec i dotaz —
-- kdyby to byly tři různé implementace, rozešly by se do měsíce a projevilo
-- by se to jako „hledání někdy nenajde zastávku, která tam je".
--
-- Rozsah je Latin-1 Supplement + Latin Extended-A, tedy čeština, slovenština,
-- polština, němčina, maďarština a chorvatština — celý podporovaný region.
create or replace function pt_norm(t text)
returns text
language sql
immutable
parallel safe
strict
set search_path = public
as $$
  select
    -- Tečky, pomlčky a lomítka jsou v názvech zastávek oddělovače, ne znaky:
    -- „Praha hl.n.", „Brno-Židenice", „Ústí n.L.". Uživatel je nepíše.
    btrim(regexp_replace(
      translate(
        lower(replace(replace(replace(replace(t,
          'ß', 'ss'), 'æ', 'ae'), 'Æ', 'ae'), 'œ', 'oe')),
        'ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞàáâãäåçèéêëìíîïðñòóôõöøùúûüýþÿĀāĂăĄąĆćĈĉĊċČčĎďĐđĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĦħĨĩĪīĬĭĮįİĴĵĶķĹĺĻļĽľŁłŃńŅņŇňŊŋŌōŎŏŐőŔŕŖŗŘřŚśŜŝŞşŠšŢţŤťŦŧŨũŪūŬŭŮůŰűŲųŴŵŶŷŸŹźŻżŽž',
        'AAAAAACEEEEIIIIDNOOOOOOUUUUYTaaaaaaceeeeiiiidnoooooouuuuytyAaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIJjKkLlLlLlLlNnNnNnNnOoOoOoRrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZz'
      ),
      '[^a-z0-9]+', ' ', 'g'
    ));
$$;

comment on function pt_norm is
  'Diakritika pryč, interpunkce na mezery, malá písmena. IMMUTABLE schválně: '
  'používá se v generovaném sloupci a v indexu, kam unaccent() nesmí.';

-- ---------------------------------------------------------------------------
-- 2. Registr zdrojů a licencí
-- ---------------------------------------------------------------------------
-- Tabulka z architektury §9.6, konečně vytvořená. Není to dokumentace, je to
-- provozní záznam: import odmítne feed, který tu nemá řádek, a obrazovka
-- s atribucemi ho čte. Zdroj, u kterého nikdo neověřil licenci, se do
-- databáze nedostane.
create table if not exists feed_licences (
  feed_id       text primary key,
  name          text not null,
  publisher     text not null,
  source_url    text not null,
  -- SPDX kde existuje ('CC0-1.0', 'CC-BY-4.0'), jinak krátký popis.
  licence       text not null,
  licence_url   text,
  -- NULL znamená „attribution se nevyžaduje" (CC0, volné dílo), ne „ještě
  -- jsme to nezjistili". Nezjištěno = řádek neexistuje.
  attribution   text,
  commercial_ok boolean not null,
  update_freq   text,
  checked_at    date not null,
  notes         text,
  last_import   timestamptz,
  stop_count    int not null default 0
);

comment on table feed_licences is
  'Zdroje dat o zastávkách a jejich licence. Feed bez řádku se neimportuje.';

alter table feed_licences enable row level security;
-- Žádná policy pro authenticated: atribuce chodí do klienta přes
-- transit_attributions(), ne přímým selectem.
revoke all on feed_licences from authenticated, anon;

insert into feed_licences (
  feed_id, name, publisher, source_url,
  licence, licence_url, attribution, commercial_ok,
  update_freq, checked_at, notes
) values
  (
    'cisjr_jdf',
    'CIS JŘ — jízdní řády veřejné linkové dopravy (JDF)',
    'Ministerstvo dopravy ČR (provozuje CHAPS spol. s r.o.)',
    'https://portal.cisjr.cz/pub/JDF/JDF.zip',
    'volné dílo (bez autorskoprávní ochrany)',
    'https://data.gov.cz/datová-sada?iri=https%3A%2F%2Fdata.gov.cz%2Fzdroj%2Fdatov%C3%A9-sady%2F66003008%2F1463646434',
    null,
    true,
    '3× týdně',
    date '2026-08-08',
    'NKOD u distribuce uvádí: není autorským dílem, není chráněna zvláštním '
    'právem pořizovatele databáze. Tedy volné užití včetně komerčního a bez '
    'povinné atribuce. JDF nenese souřadnice — ty se doplňují z GTFS zdrojů, '
    'proto je JDF fallback a ne primární zdroj polohy.'
  ),
  (
    'czptt',
    'CZPTT — jízdní řády vlaků v ČR, konverze do GTFS',
    'Správa železnic (data), komunitní konverze data.jr.ggu.cz',
    'https://data.jr.ggu.cz/results/latest/CZPTT_GTFS.zip',
    'CC0-1.0',
    'https://creativecommons.org/publicdomain/zero/1.0/',
    null,
    true,
    'denně',
    date '2026-08-08',
    'Licence deklarovaná v registru feedů projektu Transitous. Před prvním '
    'eurem ověřit přímo u provozovatele konverze a poznámku aktualizovat.'
  ),
  (
    'pid',
    'PID — Pražská integrovaná doprava',
    'ROPID / IDSK',
    'https://data.pid.cz/PID_GTFS.zip',
    'CC-BY-4.0',
    'https://creativecommons.org/licenses/by/4.0/',
    'Data © ROPID, licence CC BY 4.0',
    true,
    'denně',
    date '2026-08-08',
    'Jediný zdroj, který nese okres, obec, IDOS název a rozlišení vlak / '
    'ostatní. Pro Prahu a Střední Čechy je proto autoritativní.'
  )
on conflict (feed_id) do update set
  licence     = excluded.licence,
  attribution = excluded.attribution,
  checked_at  = excluded.checked_at,
  notes       = excluded.notes;

-- ---------------------------------------------------------------------------
-- 3. Druh zastávky
-- ---------------------------------------------------------------------------
-- Wire hodnoty jsou kontrakt s importem a s Flutterem — enum serializovaný
-- přes .name je jedno přejmenování od tiché ztráty dat (past 12).
do $$
begin
  if not exists (select 1 from pg_type where typname = 'stop_mode') then
    create type stop_mode as enum (
      'train', 'metro', 'tram', 'trolleybus', 'bus',
      'ferry', 'funicular', 'cablecar', 'other'
    );
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Fyzické zastávky
-- ---------------------------------------------------------------------------
-- Jeden řádek = jeden sloupek / jedno nástupiště, přesně jak ho vydal zdroj.
-- Zůstává tu proto, že bez source_stop_id se nedá udělat inkrementální
-- update ani poslat MOTISu konkrétní stop, a bez souřadnice sloupku se nedá
-- spočítat pěší leg.
--
-- Uživatel tuhle tabulku nikdy nevidí — hledá v transit_places (§5).
create table if not exists transit_stops (
  id               uuid primary key default gen_random_uuid(),
  feed_id          text not null references feed_licences(feed_id) on delete cascade,
  -- ID poskytovatele, nikdy nepřegenerované. Bez něj je import destruktivní.
  source_stop_id   text not null,
  name             text not null,
  point            geography(point, 4326) not null,
  mode             stop_mode not null default 'other',
  -- GTFS location_type: 0 stop, 1 station, 2 vchod, 3 uzel, 4 nástupní plocha.
  location_type    smallint not null default 0,
  -- Ponecháno jako ID zdroje; na uuid se rozřeší až druhým průchodem importu,
  -- protože parent může v souboru přijít až za potomkem.
  source_parent_id text,
  parent_id        uuid references transit_stops(id) on delete set null,
  city             text,
  -- Okres. Tohle je sloupec, který odlišuje čtyři různé Chrášťany —
  -- bez něj má hledání čtyři nerozlišitelné řádky.
  district         text,
  region           text,
  country          char(2) not null default 'CZ',
  -- GTFS wheelchair_boarding: 0 neznámo, 1 ano, 2 ne.
  wheelchair       smallint,
  platform_code    text,
  zone_id          text,
  timezone         text not null default 'Europe/Prague',
  -- Kolik spojů tady staví. Není to dekorace: je to jediný objektivní
  -- podklad pro to, aby „Praha hl.n." vyhrálo nad „Praha-Zahradní Město".
  departures_per_day int not null default 0,
  first_seen_at    timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- Import needeletuje. Zastávka, která ve feedu zmizela, se označí a po dvou
  -- aktualizacích vypadne — dopravce ji mohl jen dočasně vyřadit z provozu a
  -- výlet, který na ni ukazuje, nesmí zůstat bez souřadnic.
  retired_at       timestamptz,
  unique (feed_id, source_stop_id)
);

create index if not exists transit_stops_point_idx
  on transit_stops using gist (point);
create index if not exists transit_stops_parent_idx
  on transit_stops (parent_id) where parent_id is not null;
create index if not exists transit_stops_live_idx
  on transit_stops (feed_id) where retired_at is null;

alter table transit_stops enable row level security;
revoke all on transit_stops from authenticated, anon;

-- ---------------------------------------------------------------------------
-- 5. Místa — to, co uživatel hledá a vybírá
-- ---------------------------------------------------------------------------
-- Proč druhá tabulka a ne jen hledání nad transit_stops:
--
-- „Praha, Florenc" je ve zdrojích osm sloupků, „Anděl" devět, metro má dva
-- stopy na stanici a nádraží nástupiště. Kdyby hledání vracelo fyzické
-- zastávky, uživatel po napsání „florenc" dostane osm identických řádků a
-- musí si vybrat sloupek, o kterém nemůže nic vědět. IDOS to nedělá a my
-- taky ne.
--
-- Místo je tedy skupina zastávek se stejným názvem, ve stejné obci, stejné
-- rodiny (kolejová / silniční). Rodina je v tom rozdělení schválně: „Praha
-- hl.n." vlak a „Praha, Hlavní nádraží" tramvaj jsou dvě různá místa, ze
-- kterých se jede jinam, a PID sám je rozlišuje příznakem isTrain.
create table if not exists transit_places (
  id            uuid primary key default gen_random_uuid(),
  -- Deterministicky odvozený z názvu, obce a rodiny. Stabilní mezi importy,
  -- takže uložený výběr uživatele přežije aktualizaci dat.
  group_key     text not null unique,
  name          text not null,
  city          text,
  district      text,
  region        text,
  country       char(2) not null default 'CZ',
  mode          stop_mode not null,
  modes         stop_mode[] not null default '{}',
  -- Těžiště členů. U nádraží to je střed kolejiště, u autobusového uzlu
  -- střed sloupků — v obou případech dost přesné pro pěší leg a pro počasí.
  point         geography(point, 4326) not null,
  stop_count    int not null default 1,
  wheelchair    smallint,
  departures_per_day int not null default 0,
  -- Prefixovaný a fuzzy prohledávaný text. Generovaný, ne plněný importem:
  -- kdyby ho plnil import, mohl by se rozejít s pt_norm() v dotazu.
  search_text   text generated always as (
    pt_norm(coalesce(name, '') || ' ' ||
            coalesce(city, '') || ' ' ||
            coalesce(district, ''))
  ) stored,
  norm_name     text generated always as (pt_norm(coalesce(name, ''))) stored,
  feeds         text[] not null default '{}',
  updated_at    timestamptz not null default now()
);

-- GIN trigram nese jak LIKE '%x%', tak similarity() — obojí ve stejném
-- indexu. Bez něj je hledání nad 60 tisíci zastávkami sekvenční sken.
create index if not exists transit_places_search_trgm_idx
  on transit_places using gin (search_text gin_trgm_ops);
create index if not exists transit_places_name_trgm_idx
  on transit_places using gin (norm_name gin_trgm_ops);
create index if not exists transit_places_point_idx
  on transit_places using gist (point);
-- Prefix „praha%" je nejčastější případ a btree ho zvládne líp než trigram.
create index if not exists transit_places_prefix_idx
  on transit_places (search_text text_pattern_ops);

alter table transit_places enable row level security;
-- Schválně žádná policy. Zastávky jsou veřejná referenční data, ale klient
-- si je nesmí stáhnout celé — zadání M7 to zakazuje a bez tohohle by to bylo
-- na jeden select. Ven vede jenom search_transit_stops() (§8).
revoke all on transit_places from authenticated, anon;

-- Vazba místo → jeho fyzické zastávky. MOTIS dostane konkrétní stop IDs,
-- ne jenom souřadnici, kdykoli je zná.
create table if not exists transit_place_stops (
  place_id uuid not null references transit_places on delete cascade,
  stop_id  uuid not null references transit_stops  on delete cascade,
  primary key (place_id, stop_id)
);
create index if not exists transit_place_stops_stop_idx
  on transit_place_stops (stop_id);

alter table transit_place_stops enable row level security;
revoke all on transit_place_stops from authenticated, anon;

-- ---------------------------------------------------------------------------
-- 6. Import — staging a idempotentní přepis
-- ---------------------------------------------------------------------------
-- Pipeline nahraje celý feed sem (COPY, jeden příkaz), pak zavolá
-- import_transit_stops(). Dvě fáze proto, že jinak by se běžící aplikace
-- dívala na napůl nahraná data, a proto, že upsert proti staging tabulce je
-- jeden příkaz místo šedesáti tisíc.
create unlogged table if not exists transit_stops_staging (
  feed_id          text not null,
  source_stop_id   text not null,
  name             text not null,
  lat              double precision not null,
  lon              double precision not null,
  mode             text not null default 'other',
  location_type    smallint not null default 0,
  source_parent_id text,
  city             text,
  district         text,
  region           text,
  country          char(2) not null default 'CZ',
  wheelchair       smallint,
  platform_code    text,
  zone_id          text,
  timezone         text not null default 'Europe/Prague',
  departures_per_day int not null default 0
);

alter table transit_stops_staging enable row level security;
revoke all on transit_stops_staging from authenticated, anon;

create or replace function import_transit_stops(p_feed text)
returns table (inserted int, updated int, retired int, revived int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before int;
  v_ins    int;
  v_upd    int;
  v_ret    int;
  v_rev    int;
begin
  if not exists (select 1 from feed_licences where feed_id = p_feed) then
    raise exception
      'feed % nemá řádek ve feed_licences — nejdřív ověř licenci', p_feed
      using errcode = '23503';
  end if;

  if not exists (select 1 from transit_stops_staging where feed_id = p_feed) then
    raise exception 'staging je pro feed % prázdný', p_feed
      using errcode = '22000';
  end if;

  -- Souřadnice 0,0 je Guinejský záliv a v datech to znamená „chybí". Pustit
  -- ji dál by znamenalo zastávku, která je od všeho stejně daleko a v každém
  -- hledání podle vzdálenosti vyhraje nebo prohraje ze špatného důvodu.
  delete from transit_stops_staging
  where feed_id = p_feed
    and (abs(lat) < 0.01 and abs(lon) < 0.01
         or lat not between -90 and 90
         or lon not between -180 and 180
         or btrim(name) = '');

  select count(*) into v_before from transit_stops where feed_id = p_feed;

  -- Duplicitní source_stop_id ve stejném feedu: vyhrává řádek s víc odjezdy,
  -- při shodě ten s delším názvem. Deterministicky, ne náhodně — jinak by
  -- dva běhy importu daly dvě různé databáze.
  with src as (
    select distinct on (source_stop_id) *
    from transit_stops_staging
    where feed_id = p_feed
    order by source_stop_id, departures_per_day desc, length(name) desc, name
  ),
  up as (
    insert into transit_stops as ts (
      feed_id, source_stop_id, name, point, mode, location_type,
      source_parent_id, city, district, region, country,
      wheelchair, platform_code, zone_id, timezone, departures_per_day,
      updated_at, retired_at
    )
    select
      s.feed_id, s.source_stop_id, btrim(s.name),
      st_setsrid(st_makepoint(s.lon, s.lat), 4326)::geography,
      s.mode::stop_mode, s.location_type,
      s.source_parent_id, s.city, s.district, s.region, s.country,
      s.wheelchair, s.platform_code, s.zone_id, s.timezone,
      s.departures_per_day,
      now(), null
    from src s
    on conflict (feed_id, source_stop_id) do update set
      name             = excluded.name,
      point            = excluded.point,
      mode             = excluded.mode,
      location_type    = excluded.location_type,
      source_parent_id = excluded.source_parent_id,
      city             = excluded.city,
      district         = excluded.district,
      region           = excluded.region,
      country          = excluded.country,
      wheelchair       = excluded.wheelchair,
      platform_code    = excluded.platform_code,
      zone_id          = excluded.zone_id,
      timezone         = excluded.timezone,
      departures_per_day = excluded.departures_per_day,
      updated_at       = now(),
      retired_at       = null
    returning (xmax = 0) as was_insert, (ts.retired_at is null) as live
  )
  select
    count(*) filter (where was_insert)::int,
    count(*) filter (where not was_insert)::int
  into v_ins, v_upd
  from up;

  -- Co ve feedu není, se označí. Nemaže se: výlet, který na zastávku
  -- ukazuje, by přišel o souřadnice, a dopravce ji mohl jen na měsíc zrušit.
  update transit_stops ts
     set retired_at = now(), updated_at = now()
   where ts.feed_id = p_feed
     and ts.retired_at is null
     and not exists (
       select 1 from transit_stops_staging s
       where s.feed_id = p_feed and s.source_stop_id = ts.source_stop_id
     );
  get diagnostics v_ret = row_count;

  v_rev := 0;

  -- Parent stations druhým průchodem: ve zdroji může potomek přijít dřív než
  -- rodič, takže při vkládání ještě uuid neexistuje.
  update transit_stops c
     set parent_id = p.id
    from transit_stops p
   where c.feed_id = p_feed
     and c.source_parent_id is not null
     and p.feed_id = c.feed_id
     and p.source_stop_id = c.source_parent_id
     and c.parent_id is distinct from p.id;

  delete from transit_stops_staging where feed_id = p_feed;

  update feed_licences
     set last_import = now(),
         stop_count  = (select count(*) from transit_stops
                        where feed_id = p_feed and retired_at is null)
   where feed_id = p_feed;

  return query select v_ins, v_upd, v_ret, v_rev;
end;
$$;

comment on function import_transit_stops is
  'Idempotentní: dvakrát puštěný stejný feed dá stejnou databázi. Nemaže, '
  'označuje. Volá se ze service_role po naplnění transit_stops_staging.';

revoke execute on function import_transit_stops(text) from public, authenticated, anon;

-- ---------------------------------------------------------------------------
-- 7. Přepočet míst
-- ---------------------------------------------------------------------------
-- Odvozená tabulka, ne pohled: hledání nad ní musí být indexované a pohled
-- nad šedesáti tisíci zastávkami s agregací by se nedal proindexovat.
--
-- Když se feedy o jedné zastávce neshodnou (PID i CZPTT znají „Praha
-- hl.n."), rozhoduje počet odjezdů — deterministicky, ne podle pořadí
-- importu. Kdyby rozhodovalo pořadí, dva stejné běhy dají dvě různé
-- databáze a nikdo si toho nevšimne.
create or replace function rebuild_transit_places()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  -- Shlukování, ne klíč z metadat.
  --
  -- První verze skládala klíč ze jména, okresu a rodiny. Okres ale zná jenom
  -- PID; zbytek feedů nenese ani obec, takže by fallback musel být mřížka
  -- souřadnic — a ta rozsekne „Praha, Florenc" na dvě místa pokaždé, když
  -- dva sloupky padnou přes hranici buňky.
  --
  -- ST_ClusterDBSCAN dělá to, co se od toho čeká: stejnojmenné zastávky
  -- spojí, dokud jsou řetězem do 5 km od sebe. Osm sloupků Florence je jeden
  -- shluk, čtvery Chrášťany čtyři. Metadata (obec, okres) tím přestala být
  -- identitou a zůstala popiskem, což je jediná role, kterou unesou.
  create temporary table _clust on commit drop as
  select
    s.id as stop_id,
    s.name, s.city, s.district, s.region, s.country,
    s.mode, s.point, s.wheelchair, s.departures_per_day, s.feed_id,
    pt_norm(s.name) as norm_name,
    -- Kolejová doprava se od silniční odděluje proto, že „Kolín" vlak a
    -- „Kolín, aut.nádr." jsou dvě různá místa a spoj mezi nimi je pěší
    -- přesun, ne přestup na stejné zastávce.
    case when s.mode in ('train', 'metro') then 'rail' else 'road' end
      as family,
    st_clusterdbscan(s.point::geometry, eps => 0.05, minpoints => 1)
      over (
        partition by pt_norm(s.name),
                     case when s.mode in ('train', 'metro')
                          then 'rail' else 'road' end
      ) as cluster_id
  from transit_stops s
  where s.retired_at is null
    -- location_type 2/3/4 jsou vchody, uzly a nástupní plochy. Nejsou to
    -- zastávky a v seznamu k výběru nemají co dělat.
    and s.location_type in (0, 1);

  create index on _clust (norm_name, family, cluster_id);

  create temporary table _grp on commit drop as
  with live as (select * from _clust)
  select
    -- Klíč z těžiště shluku, zaokrouhleného na ~1 km. Přidaný sloupek
    -- těžištěm osmičlenného uzlu prakticky nehne, takže uložený výběr
    -- uživatele přežije aktualizaci dat. Kdyby přesto zmizel, výlet drží
    -- vlastní souřadnice a jméno a nerozbije se.
    norm_name || '|' || family || '|' ||
      round(st_y(st_centroid(st_collect(point::geometry)))::numeric, 2)::text
      || ',' ||
      round(st_x(st_centroid(st_collect(point::geometry)))::numeric, 2)::text
      as group_key,
    norm_name,
    family,
    cluster_id,
    -- Zobrazovaný název: nejčastější varianta, při shodě delší. Feedy píšou
    -- „Praha hl.n." i „Praha hlavní nádraží" a vybrat se musí jeden, pořád
    -- stejný.
    (array_agg(name order by departures_per_day desc, length(name) desc, name))[1]
      as name,
    (array_agg(city     order by (city is null), departures_per_day desc))[1] as city,
    (array_agg(district order by (district is null), departures_per_day desc))[1] as district,
    (array_agg(region   order by (region is null), departures_per_day desc))[1] as region,
    (array_agg(country  order by departures_per_day desc))[1] as country,
    (array_agg(mode     order by departures_per_day desc, mode))[1] as mode,
    array_agg(distinct mode) as modes,
    st_centroid(st_collect(point::geometry))::geography as point,
    count(*)::int as stop_count,
    -- Bezbariérovost skupiny: 1 (ano) jen když to tvrdí aspoň jeden sloupek.
    max(nullif(wheelchair, 0))::smallint as wheelchair,
    sum(departures_per_day)::int as departures_per_day,
    array_agg(distinct feed_id) as feeds,
    -- Členové se nesou s sebou. Odvozovat je podruhé stejným výrazem by
    -- znamenalo dvě kopie definice klíče, které se dřív nebo později
    -- rozejdou — a projeví se to jako místo bez zastávek.
    array_agg(stop_id) as stop_ids
  from live
  -- Podle shluku, ne podle group_key: group_key je agregát (těžiště) a
  -- podle agregátu se seskupovat nedá.
  group by norm_name, family, cluster_id;

  create index on _grp (group_key);

  insert into transit_places as p (
    group_key, name, city, district, region, country,
    mode, modes, point, stop_count, wheelchair, departures_per_day,
    feeds, updated_at
  )
  select
    group_key, name, city, district, region, country,
    mode, modes, point, stop_count, wheelchair, departures_per_day,
    feeds, now()
  from _grp
  on conflict (group_key) do update set
    name       = excluded.name,
    city       = excluded.city,
    district   = excluded.district,
    region     = excluded.region,
    country    = excluded.country,
    mode       = excluded.mode,
    modes      = excluded.modes,
    point      = excluded.point,
    stop_count = excluded.stop_count,
    wheelchair = excluded.wheelchair,
    departures_per_day = excluded.departures_per_day,
    feeds      = excluded.feeds,
    updated_at = now();

  -- Místo, jehož všechny zastávky zmizely. Mažeme, protože na rozdíl od
  -- zastávky nenese ID poskytovatele a jeho group_key se z dat kdykoli
  -- znovu odvodí — uložený výběr ve výletu drží vlastní souřadnice.
  delete from transit_places p
  where not exists (select 1 from _grp g where g.group_key = p.group_key);

  -- Vazba místo → zastávky, celá znovu. Levnější než diff a nemůže se
  -- rozejít.
  delete from transit_place_stops;
  insert into transit_place_stops (place_id, stop_id)
  select p.id, unnest(g.stop_ids)
  from _grp g
  join transit_places p on p.group_key = g.group_key
  on conflict do nothing;

  select count(*)::int into v_count from transit_places;

  analyze transit_places;
  analyze transit_stops;

  return v_count;
end;
$$;

revoke execute on function rebuild_transit_places() from public, authenticated, anon;

-- ---------------------------------------------------------------------------
-- 8. Hledání
-- ---------------------------------------------------------------------------
-- Jediná cesta, kterou se klient k zastávkám dostane.
--
-- Skóre je vážený součet, ne kaskáda if — kaskáda znamená, že přesná shoda
-- na nedůležité zastávce porazí prefix na hlavním nádraží, což je přesně to,
-- co uživatel po napsání „praha hl" nechce.
--
-- Vzdálenost je bonus, ne filtr. Když někdo v Ostravě hledá „Praha hl.n.",
-- musí ji najít.
create or replace function search_transit_stops(
  p_query text,
  p_lat   double precision default null,
  p_lon   double precision default null,
  p_limit int default 12
)
returns table (
  id            uuid,
  name          text,
  city          text,
  district      text,
  region        text,
  country       char(2),
  mode          stop_mode,
  modes         stop_mode[],
  lat           double precision,
  lon           double precision,
  stop_count    int,
  wheelchair    smallint,
  distance_km   double precision,
  score         double precision
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_q      text := pt_norm(coalesce(p_query, ''));
  v_tokens text[];
  v_here   geography;
  v_limit  int := least(greatest(coalesce(p_limit, 12), 1), 50);
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- Jeden znak je pro trigram k ničemu a vrátil by půl databáze. Dva jsou
  -- minimum, u kterého má prefix smysl.
  if length(v_q) < 2 then
    return;
  end if;

  v_tokens := regexp_split_to_array(btrim(v_q), '\s+');

  if p_lat is not null and p_lon is not null
     and p_lat between -90 and 90 and p_lon between -180 and 180 then
    v_here := st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography;
  end if;

  return query
  with cand as (
    select p.*
    from transit_places p
    where
      -- Každý token musí být obsažen. „cerny most" nesmí najít „Most".
      p.search_text like all (
        select '%' || t || '%' from unnest(v_tokens) t
      )
    -- Kandidátů schválně víc, než kolik se vrátí: řazení podle skóre se dělá
    -- až nad nimi a bez rezervy by ořez limitem zahodil vítěze.
    limit 400
  ),
  fuzzy as (
    -- Záchranná síť na překlepy. Pouští se jen když prefixové hledání
    -- nenašlo skoro nic — similarity() nad celou tabulkou je drahá.
    select p.*
    from transit_places p
    where (select count(*) from cand) < 5
      and p.norm_name % v_q
    order by similarity(p.norm_name, v_q) desc
    limit 40
  ),
  pool as (
    select * from cand
    union
    select * from fuzzy
  ),
  scored as (
    select
      p.id, p.name, p.city, p.district, p.region, p.country,
      p.mode, p.modes,
      st_y(p.point::geometry) as lat,
      st_x(p.point::geometry) as lon,
      p.stop_count, p.wheelchair,
      case when v_here is null then null
           else st_distance(p.point, v_here) / 1000.0 end as distance_km,
      (
        -- Přesná shoda názvu.
        case when p.norm_name = v_q then 3.0 else 0.0 end
        -- Název začíná dotazem: „praha hl" → „Praha hl.n.".
        + case when p.norm_name like v_q || '%' then 2.0 else 0.0 end
        -- Dotaz začíná na hranici slova: „most" najde „Černý Most".
        + case when p.search_text ~ ('(^|\s)' || v_tokens[1]) then 0.8
               else 0.0 end
        -- Podobnost pro překlepy a zkratky.
        + 1.2 * similarity(p.norm_name, v_q)
        -- Význam zastávky. log, ne lineárně: hlavní nádraží má o dva řády
        -- víc odjezdů než vesnická zastávka a lineárně by přebilo všechno.
        + least(1.0, ln(1 + p.departures_per_day) / 8.0)
        -- Kolejová doprava mírně napřed. Kdo píše jméno města, myslí
        -- obvykle nádraží, ne konkrétní sloupek autobusu.
        + case when p.mode in ('train', 'metro') then 0.25 else 0.0 end
        -- Blízkost. Nula na místě, plný odečet nad 200 km — dost na to, aby
        -- v Praze vyhrály pražské zastávky, málo na to, aby se Brno ztratilo.
        - case when v_here is null then 0.0
               else least(1.0, st_distance(p.point, v_here) / 200000.0) * 0.9
          end
      ) as score
    from pool p
  )
  select s.id, s.name, s.city, s.district, s.region, s.country,
         s.mode, s.modes, s.lat, s.lon, s.stop_count, s.wheelchair,
         s.distance_km, s.score
  from scored s
  -- Determinismus: dvě zastávky se stejným skóre musí vyjít pokaždé ve
  -- stejném pořadí, jinak seznam pod prstem poskakuje.
  order by s.score desc, s.name, s.id
  limit v_limit;
end;
$$;

comment on function search_transit_stops is
  'Server-side hledání zastávek: prefix, fuzzy, bez diakritiky, řazení podle '
  'významu a vzdálenosti. Jediná cesta klienta k transit_places.';

grant execute on function search_transit_stops(
  text, double precision, double precision, int
) to authenticated;

-- Rehydratace uloženého výběru. Výlet drží place_id; když se otevře na jiném
-- zařízení, tohle je jediný způsob, jak k němu dostat jméno a souřadnice.
create or replace function transit_place(p_id uuid)
returns table (
  id uuid, name text, city text, district text, region text,
  country char(2), mode stop_mode, modes stop_mode[],
  lat double precision, lon double precision,
  stop_count int, wheelchair smallint
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, p.name, p.city, p.district, p.region, p.country,
         p.mode, p.modes,
         st_y(p.point::geometry), st_x(p.point::geometry),
         p.stop_count, p.wheelchair
  from transit_places p
  where p.id = p_id and auth.uid() is not null;
$$;

grant execute on function transit_place(uuid) to authenticated;

-- Atribuce pro obrazovku „O aplikaci". CC BY není volitelné a tohle je
-- jediný způsob, jak se seznam nemůže rozejít s tím, co je opravdu naimportované.
create or replace function transit_attributions()
returns table (name text, attribution text, licence text, licence_url text)
language sql
security definer
set search_path = public
stable
as $$
  select f.name, f.attribution, f.licence, f.licence_url
  from feed_licences f
  where f.attribution is not null
    and f.stop_count > 0
  order by f.name;
$$;

grant execute on function transit_attributions() to authenticated, anon;

-- Prázdná databáze zastávek není totéž co „nic jsme nenašli".
--
-- Mezi touhle migrací a prvním během importu je aplikace ve stavu, kdy
-- hledání legitimně nevrací nic. Bez tohohle by picker hlásil „zkuste jiný
-- tvar názvu" a stálo by to jedno kolo hledání chyby, která žádná není —
-- přesně ta věc, kterou session 2 zaplatila čtyřikrát.
create or replace function transit_data_status()
returns table (places int, stops int, last_import timestamptz)
language sql
security definer
set search_path = public
stable
as $$
  select
    (select count(*)::int from transit_places),
    (select count(*)::int from transit_stops where retired_at is null),
    (select max(last_import) from feed_licences)
  where auth.uid() is not null;
$$;

grant execute on function transit_data_status() to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Napojení na výlet
-- ---------------------------------------------------------------------------
-- Výlet si drží ID místa i jeho souřadnice. Vypadá to jako duplicita a není:
-- ID je to, co pošleme MOTISu, souřadnice jsou to, čím se výlet nerozbije,
-- když se místo při další aktualizaci dat přeskupí nebo zmizí.
alter table trips
  add column if not exists origin_place_id      uuid references transit_places on delete set null,
  add column if not exists destination_place_id uuid references transit_places on delete set null;

comment on column trips.origin_place_id is
  'Konkrétní zastávka odjezdu. origin_point zůstává zdrojem pravdy pro '
  'geometrii — místo může při aktualizaci dat zmizet, výlet ne.';

create index if not exists trips_origin_place_idx
  on trips (origin_place_id) where origin_place_id is not null;

-- Nová funkce, ne přidaný parametr do set_trip_destination: parametr
-- s DEFAULT vyrobí nejednoznačné přetížení, ne náhradu (past 2 ze session 2).
create or replace function set_trip_destination_stop(
  p_trip  uuid,
  p_place uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_pt   geography;
begin
  if not is_trip_organiser(p_trip) then
    raise exception 'only the organiser can set the destination'
      using errcode = '42501';
  end if;

  select p.name, p.point into v_name, v_pt
  from transit_places p where p.id = p_place;

  if not found then
    raise exception 'unknown stop %', p_place using errcode = '22000';
  end if;

  update trips
     set destination_id      = null,
         destination_free    = v_name,
         destination_point   = v_pt,
         destination_place_id = p_place
   where id = p_trip;
end;
$$;

grant execute on function set_trip_destination_stop(uuid, uuid) to authenticated;

create or replace function set_trip_origin_stop(
  p_trip  uuid,
  p_place uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_pt   geography;
begin
  if not is_trip_organiser(p_trip) then
    raise exception 'only the organiser can move the origin'
      using errcode = '42501';
  end if;

  select p.name, p.point into v_name, v_pt
  from transit_places p where p.id = p_place;

  if not found then
    raise exception 'unknown stop %', p_place using errcode = '22000';
  end if;

  update trips
     set origin_label    = v_name,
         origin_point    = v_pt,
         origin_place_id = p_place
   where id = p_trip;
end;
$$;

grant execute on function set_trip_origin_stop(uuid, uuid) to authenticated;

-- create_trip dostává výchozí zastávku. Starou signaturu je nutné dropnout
-- ve stejné migraci — parametr s DEFAULT nevytvoří náhradu, ale druhé
-- přetížení, na které pak staré volání sedí stejně dobře jako na nové.
drop function if exists create_trip(
  text, text, double precision, double precision, timestamptz, timestamptz,
  int, transport_pref, numeric, text[], text, time, char(3),
  text, int, int, time, time
);

create function create_trip(
  p_title             text,
  p_origin_label      text,
  p_origin_lat        double precision,
  p_origin_lon        double precision,
  p_window_start      timestamptz,
  p_window_end        timestamptz,
  p_duration_days     int      default 1,
  p_transport         transport_pref default 'either',
  p_budget_per_person numeric  default null,
  p_activity_tags     text[]   default '{}',
  p_description       text     default null,
  p_earliest_wake     time     default null,
  p_currency          char(3)  default 'CZK',
  p_granularity       text     default 'day',
  p_slot_minutes      int      default null,
  p_slot_step_minutes int      default 30,
  p_day_start         time     default '07:00',
  p_day_end           time     default '21:00',
  p_origin_place      uuid     default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip  uuid;
  v_user  uuid := auth.uid();
  v_days  int;
  v_label text := p_origin_label;
  v_point geography;
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if exists (select 1 from auth.users where id = v_user and is_anonymous) then
    raise exception 'anonymous users cannot create trips' using errcode = '42501';
  end if;

  if p_window_end <= p_window_start then
    raise exception 'window end must be after start' using errcode = '22000';
  end if;

  if p_granularity not in ('day', 'time') then
    raise exception 'unknown granularity %', p_granularity using errcode = '22000';
  end if;

  v_days := (p_window_end::date - p_window_start::date) + 1;

  if p_granularity = 'time' and v_days > 42 then
    raise exception 'a time-based trip cannot span more than 6 weeks'
      using errcode = '22000';
  end if;

  if p_granularity = 'time'
     and (p_slot_minutes is null or p_slot_minutes < 15) then
    raise exception 'a time-based trip needs an activity length'
      using errcode = '22000';
  end if;

  -- Zastávka vyhrává nad poslanými souřadnicemi. Klient je posílá taky, aby
  -- výlet šel založit i ve chvíli, kdy je databáze zastávek prázdná — což je
  -- stav mezi touhle migrací a prvním během importu.
  if p_origin_place is not null then
    select p.name, p.point into v_label, v_point
    from transit_places p where p.id = p_origin_place;
    if not found then
      raise exception 'unknown stop %', p_origin_place using errcode = '22000';
    end if;
  else
    if p_origin_lat is null or p_origin_lon is null then
      raise exception 'a trip needs an origin' using errcode = '22000';
    end if;
    v_point := st_setsrid(st_makepoint(p_origin_lon, p_origin_lat), 4326)::geography;
  end if;

  insert into trips (
    created_by, title, description, status,
    origin_label, origin_point, origin_place_id, date_window,
    duration_days, transport, budget_per_person, currency,
    activity_tags, earliest_wake,
    granularity, slot_minutes, slot_step_minutes, day_start, day_end
  ) values (
    v_user, p_title, p_description, 'planning',
    v_label, v_point, p_origin_place,
    tstzrange(p_window_start, p_window_end, '[)'),
    p_duration_days, p_transport, p_budget_per_person, p_currency,
    p_activity_tags, p_earliest_wake,
    p_granularity::trip_granularity,
    case when p_granularity = 'time' then p_slot_minutes end,
    p_slot_step_minutes, p_day_start, p_day_end
  )
  returning id into v_trip;

  insert into trip_participants (trip_id, user_id, role, status)
  values (v_trip, v_user, 'organiser', 'confirmed');

  return v_trip;
end;
$$;

-- Drop vzal grant s sebou (past 1 ze session 2) — bez tohohle řádku přestane
-- fungovat zakládání výletů a vypadá to jako chyba v aplikaci.
grant execute on function create_trip(
  text, text, double precision, double precision, timestamptz, timestamptz,
  int, transport_pref, numeric, text[], text, time, char(3),
  text, int, int, time, time, uuid
) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Read model
-- ---------------------------------------------------------------------------
-- Znovu vytvořený, ne nahrazený: přibývají sloupce a CREATE OR REPLACE VIEW
-- je umí přidat jen na konec, což by rozhodilo pořadí (past 8).
drop view if exists trips_list;

create view trips_list
with (security_invoker = true)
as
select
  t.id,
  t.title,
  t.description,
  t.status,
  t.origin_label,
  st_y(t.origin_point::geometry) as origin_lat,
  st_x(t.origin_point::geometry) as origin_lon,
  t.origin_place_id,
  lower(t.date_window)           as window_start,
  upper(t.date_window)           as window_end,
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
  (select count(*) from trip_participants p where p.trip_id = t.id)
    as participant_count,
  (select count(*) from trip_participants p
    where p.trip_id = t.id and p.calendar_shared) as calendar_shared_count,
  (select p.role from trip_participants p
    where p.trip_id = t.id and p.user_id = auth.uid()) as my_role
from trips t;

grant select on trips_list to authenticated;
