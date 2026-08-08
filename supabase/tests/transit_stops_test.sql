-- M7 — databáze zastávek, import a hledání.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/transit_stops_test.sql
--
-- Běží jako role `authenticated`, ne jako postgres. Chyba v grantech je pro
-- postgres z principu neviditelná a přesně na tom padlo připojení kalendáře
-- v session 3 — testy tehdy byly zelené a aplikace hlásila „permission
-- denied".
--
-- Data jsou vymyšlená, ale tvar je skutečný: osm sloupků jedné Florence,
-- dvoje stejnojmenné Chrášťany, vlak a tramvaj na jednom nádraží.
-- Ta trojice je celý důvod, proč existuje transit_places.

begin;
set local role postgres;

-- ---------------------------------------------------------------------------
-- Uživatel, který se ptá
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at,
                        created_at, updated_at)
values ('a1a1a1a1-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'stops@t.cz', now(), now(), now())
on conflict (id) do nothing;

insert into profiles (id, display_name)
values ('a1a1a1a1-0000-0000-0000-000000000001', 'Tester')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Normalizace
-- ---------------------------------------------------------------------------
do $$
begin
  assert pt_norm('Černý Most') = 'cerny most',
    format('diakritika: %s', pt_norm('Černý Most'));
  assert pt_norm('Praha hl.n.') = 'praha hl n',
    format('interpunkce: %s', quote_literal(pt_norm('Praha hl.n.')));
  assert pt_norm('Brno-Židenice') = 'brno zidenice',
    format('pomlčka: %s', pt_norm('Brno-Židenice'));
  assert pt_norm('Špindlerův Mlýn') = 'spindleruv mlyn',
    format('ů a ý: %s', pt_norm('Špindlerův Mlýn'));
  assert pt_norm('ÚSTÍ  n. L.') = 'usti n l',
    format('velká písmena a dvojmezera: %s', quote_literal(pt_norm('ÚSTÍ  n. L.')));
  raise notice 'pt_norm: OK';
end $$;

-- ---------------------------------------------------------------------------
-- Import
-- ---------------------------------------------------------------------------
insert into feed_licences (feed_id, name, publisher, source_url, licence,
                           commercial_ok, checked_at)
values ('test', 'Testovací feed', 'test', 'http://localhost', 'CC0-1.0',
        true, current_date)
on conflict (feed_id) do nothing;

create or replace function _stage(
  p_id text, p_name text, p_lat float8, p_lon float8,
  p_mode text default 'bus', p_loc int default 0,
  p_parent text default null, p_city text default null,
  p_district text default null, p_dep int default 50
) returns void language sql as $$
  insert into transit_stops_staging
    (feed_id, source_stop_id, name, lat, lon, mode, location_type,
     source_parent_id, city, district, departures_per_day)
  values ('test', p_id, p_name, p_lat, p_lon, p_mode, p_loc,
          p_parent, p_city, p_district, p_dep);
$$;

-- Osm sloupků Florence: rozeseté po dvou stech metrech, jedno místo.
select _stage('FLO' || i, 'Praha, Florenc',
              50.0895 + i * 0.0004, 14.4400 + i * 0.0004,
              'bus', 0, null, 'Praha', 'AB', 40)
from generate_series(1, 8) i;

-- Nádraží: vlak a metro. Metro je kolejové, takže patří ke stejné rodině,
-- ale jmenuje se jinak, takže je to jiné místo.
select _stage('PHLN', 'Praha hl.n.', 50.0830, 14.4356, 'train', 1,
              null, 'Praha', 'AB', 400);
select _stage('PHLN1', 'Praha hl.n.', 50.0832, 14.4358, 'train', 0,
              'PHLN', 'Praha', 'AB', 400);
select _stage('PHLNM', 'Hlavní nádraží', 50.0827, 14.4340, 'metro', 0,
              null, 'Praha', 'AB', 600);

-- Tramvaj u nádraží: silniční rodina, tedy vlastní místo. Přesně to, co
-- odděluje „vystup na nádraží" od „přestup na tramvaj".
select _stage('PHLNT', 'Praha hl.n.', 50.0824, 14.4362, 'tram', 0,
              null, 'Praha', 'AB', 300);

-- Dvoje Chrášťany, 40 km od sebe. Musí zůstat dvě.
select _stage('CHR-BN', 'Chrášťany', 49.7927, 14.5867, 'bus', 0, null,
              'Chrášťany', 'BN', 8);
select _stage('CHR-PZ', 'Chrášťany', 50.0448, 14.2591, 'bus', 0, null,
              'Chrášťany', 'PZ', 12);

-- Malá obec a Brno, aby bylo co hledat mimo Prahu.
select _stage('BRNO', 'Brno hl.n.', 49.1908, 16.6125, 'train', 1, null,
              'Brno', 'BM', 350);
select _stage('BRNOZ', 'Brno-Židenice', 49.2057, 16.6413, 'train', 0, null,
              'Brno', 'BM', 90);
select _stage('ADR', 'Adršpach', 50.6167, 16.1167, 'train', 0, null,
              'Adršpach', 'NA', 6);

-- Vchod do metra: location_type 2. Není to zastávka a v nabídce nemá co dělat.
select _stage('VCHOD', 'Hlavní nádraží – vchod', 50.0829, 14.4335, 'metro', 2,
              'PHLNM', 'Praha', 'AB', 0);

-- Souřadnice 0,0 znamenají „chybí". Import je musí zahodit.
select _stage('NULA', 'Nikde', 0, 0, 'bus', 0, null, null, null, 5);

select import_transit_stops('test');
select rebuild_transit_places();

do $$
declare n int;
begin
  select count(*) into n from transit_stops where feed_id = 'test';
  -- 8 sloupků Florence + 4 na hlavním nádraží + 2 Chrášťany + 3 na Moravě
  -- a v Adršpachu + 1 vchod do metra. Zastávka na 0,0 mezi nimi není.
  assert n = 18, format('nahráno %s zastávek místo 18', n);

  select count(*) into n from transit_stops where source_stop_id = 'NULA';
  assert n = 0, 'zastávka na souřadnicích 0,0 se dostala do databáze';

  select count(*) into n from transit_stops
  where source_stop_id = 'PHLN1' and parent_id is not null;
  assert n = 1, 'parent_station se nerozřešil na uuid';

  raise notice 'import: OK';
end $$;

-- ---------------------------------------------------------------------------
-- Shlukování do míst
-- ---------------------------------------------------------------------------
do $$
declare n int; c int;
begin
  select count(*), max(stop_count) into n, c
  from transit_places where name = 'Praha, Florenc';
  assert n = 1, format('osm sloupků Florence dalo %s míst', n);
  assert c = 8, format('místo Florenc má %s zastávek místo 8', c);

  select count(*) into n from transit_places where name = 'Chrášťany';
  assert n = 2, format('dvoje Chrášťany 40 km od sebe daly %s míst', n);

  -- Vlak a tramvaj stejného jména: dvě místa, protože se z nich jede jinam.
  select count(*) into n from transit_places where name = 'Praha hl.n.';
  assert n = 2, format('vlak a tramvaj na hl.n. daly %s míst místo 2', n);

  select count(*) into n from transit_places
  where name like '%vchod%';
  assert n = 0, 'vchod do metra se dostal mezi vyhledatelná místa';

  -- Idempotence. Druhý přepočet nad stejnými daty nesmí nic změnit.
  select count(*) into n from transit_places;
  perform rebuild_transit_places();
  select count(*) into c from transit_places;
  assert n = c, format('druhý přepočet změnil počet míst z %s na %s', n, c);

  raise notice 'shlukování: OK';
end $$;

-- Idempotence importu: stejná data podruhé nesmí nic zrušit ani zdvojit.
select _stage('PHLN', 'Praha hl.n.', 50.0830, 14.4356, 'train', 1,
              null, 'Praha', 'AB', 400);
select import_transit_stops('test');

do $$
declare n int;
begin
  select count(*) into n from transit_stops
  where feed_id = 'test' and source_stop_id = 'PHLN';
  assert n = 1, format('druhý import zdvojil zastávku (%s řádků)', n);

  -- Zastávky, které v druhé dávce nebyly, se označí — nesmažou.
  select count(*) into n from transit_stops
  where feed_id = 'test' and retired_at is not null;
  assert n = 17, format('%s označených místo 17', n);
  select count(*) into n from transit_stops where feed_id = 'test';
  assert n = 18, format('import mazal místo označování (%s řádků)', n);

  raise notice 'idempotence importu: OK';
end $$;

-- Vrátit je do provozu, aby na nich mohlo běžet hledání.
select _stage(s.source_stop_id, s.name,
              st_y(s.point::geometry), st_x(s.point::geometry),
              s.mode::text, s.location_type, s.source_parent_id,
              s.city, s.district, s.departures_per_day)
from transit_stops s where s.feed_id = 'test' and s.retired_at is not null;
select import_transit_stops('test');
select rebuild_transit_places();

-- ---------------------------------------------------------------------------
-- Hledání — jako authenticated, což je celý smysl tohohle souboru
-- ---------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"a1a1a1a1-0000-0000-0000-000000000001"}';

do $$
declare n int; first text;
begin
  -- Celý název města.
  select count(*) into n from search_transit_stops('Praha');
  assert n >= 3, format('„Praha" našla jen %s zastávek', n);

  -- Prefix. „praha hl" musí najít hlavní nádraží, ne cokoli s Prahou.
  select name into first from search_transit_stops('praha hl') limit 1;
  assert first = 'Praha hl.n.', format('„praha hl" vrátila napřed %s', first);

  -- Bez diakritiky. Tohle je to, co člověk jednou rukou v tramvaji napíše.
  select count(*) into n from search_transit_stops('cerny');
  -- (Černý Most v testovacích datech není; jde o to, že to nespadne.)
  assert n >= 0, 'hledání bez diakritiky spadlo';

  select name into first from search_transit_stops('brno hl') limit 1;
  assert first = 'Brno hl.n.', format('„brno hl" vrátila napřed %s', first);

  select count(*) into n from search_transit_stops('zidenice');
  assert n = 1, format('„zidenice" bez diakritiky našla %s', n);

  -- Malá obec musí být dohledatelná stejně jako krajské město.
  select count(*) into n from search_transit_stops('adrspach');
  assert n = 1, format('„adrspach" našel %s', n);

  -- Konkrétní zastávka, ne jen město.
  select count(*) into n from search_transit_stops('florenc');
  assert n = 1, format('„florenc" našla %s míst místo 1', n);

  -- Nic. Prázdný výsledek je platná odpověď, ne chyba.
  select count(*) into n from search_transit_stops('qqqxyzzy');
  assert n = 0, format('nesmysl vrátil %s výsledků', n);

  -- Jeden znak se nehledá.
  select count(*) into n from search_transit_stops('p');
  assert n = 0, 'jednopísmenný dotaz vrátil výsledky';

  -- Limit se dodržuje a je shora omezený.
  select count(*) into n from search_transit_stops('praha', null, null, 2);
  assert n <= 2, format('limit 2 vrátil %s', n);
  select count(*) into n from search_transit_stops('praha', null, null, 9999);
  assert n <= 50, format('limit 9999 vrátil %s, strop je 50', n);

  raise notice 'hledání: OK';
end $$;

-- Řazení podle vzdálenosti. Z Brna musí Brno vyhrát nad Prahou i tehdy,
-- když má Praha víc odjezdů.
do $$
declare first text;
begin
  select name into first
  from search_transit_stops('hl', 49.1908, 16.6125) limit 1;
  assert first like 'Brno%',
    format('z Brna vyšlo napřed %s, vzdálenost se do řazení nepromítla', first);

  select name into first
  from search_transit_stops('hl', 50.0830, 14.4356) limit 1;
  assert first like 'Praha%',
    format('z Prahy vyšlo napřed %s', first);

  raise notice 'řazení podle vzdálenosti: OK';
end $$;

-- Determinismus: stejný dotaz dvakrát dá stejné pořadí.
do $$
declare a text[]; b text[];
begin
  select array_agg(name order by ord) into a
  from (select name, row_number() over () ord
        from search_transit_stops('praha')) x;
  select array_agg(name order by ord) into b
  from (select name, row_number() over () ord
        from search_transit_stops('praha')) y;
  assert a = b, 'dvě stejná hledání dala dvě různá pořadí';
  raise notice 'determinismus: OK';
end $$;

-- ---------------------------------------------------------------------------
-- Bezpečnost
-- ---------------------------------------------------------------------------
do $$
declare n int;
begin
  -- Klient nesmí stáhnout celou databázi. To je požadavek M7, ne kosmetika:
  -- bez toho je server-side hledání jen doporučení.
  begin
    execute 'select count(*) from transit_places';
    raise exception 'authenticated smí číst transit_places přímo';
  exception when insufficient_privilege then
    null;
  end;

  begin
    execute 'select count(*) from transit_stops';
    raise exception 'authenticated smí číst transit_stops přímo';
  exception when insufficient_privilege then
    null;
  end;

  begin
    execute 'select count(*) from transit_stops_staging';
    raise exception 'authenticated vidí do staging tabulky';
  exception when insufficient_privilege then
    null;
  end;

  -- Import je věc service_role.
  begin
    execute $q$select import_transit_stops('test')$q$;
    raise exception 'authenticated může spustit import';
  exception when insufficient_privilege then
    null;
  end;

  begin
    execute 'select rebuild_transit_places()';
    raise exception 'authenticated může přepočítat místa';
  exception when insufficient_privilege then
    null;
  end;

  -- Neznámé ID vrátí prázdno, ne chybu a ne cizí řádek.
  select count(*) into n
  from transit_place('00000000-0000-0000-0000-000000000000');
  assert n = 0, 'neznámé ID zastávky něco vrátilo';

  raise notice 'bezpečnost: OK';
end $$;

-- Pokusy o injection. Dotaz je parametr, ne kus SQL — tohle to potvrzuje.
do $$
declare n int; m int;
begin
  select count(*) into n
  from search_transit_stops($q$'; drop table transit_places; --$q$);
  assert n = 0, 'injection vrátila výsledky';

  -- Zástupné znaky se normalizací zahodí, takže nejsou vzor ani dotaz.
  select count(*) into n from search_transit_stops('%');
  assert n = 0, 'zástupný znak prošel jako vzor';

  -- „praha%" se chová přesně jako „praha" — procento je znak, ne wildcard.
  select count(*) into n from search_transit_stops('praha%');
  select count(*) into m from search_transit_stops('praha');
  assert n = m, format('„praha%%" (%s) se liší od „praha" (%s)', n, m);

  select count(*) into n from search_transit_stops(repeat('a', 5000));
  assert n = 0, 'pětitisícový dotaz nespadl, ale ani nevrátil nesmysl';

  select count(*) into n from search_transit_stops(null);
  assert n = 0, 'null dotaz vrátil výsledky';

  raise notice 'injection: OK';
end $$;

-- Nepřihlášený uživatel nehledá.
-- Prázdné claims znamenají auth.uid() = null, tedy nepřihlášeného.
set local request.jwt.claims = '{}';
do $$
begin
  begin
    perform 1 from search_transit_stops('praha');
    raise exception 'nepřihlášený uživatel prošel';
  exception when insufficient_privilege then
    null;
  end;
  raise notice 'anonymní přístup: OK';
end $$;

rollback;
