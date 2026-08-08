-- ============================================================================
-- M7 — vyhledávání spojení: cache a tarifní pravidla.
--
-- Doprovází Edge Function transport-search. Ta drží klíče a provider-specific
-- logiku, tahle migrace to, co musí přežít restart funkce.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cache
-- ---------------------------------------------------------------------------
-- Serverová, ne klientská. Kdyby byla v klientovi, každý účastník výletu by
-- si vyžádal stejné spojení znovu a rate limit poskytovatele by vyčerpala
-- pětičlenná skupina otevírající jednu obrazovku.
--
-- Klíč nese všechno, co mění výsledek. Kdyby v něm chybělo časové okno,
-- vrátila by cache ranní vlak na dotaz na večerní — a bylo by to reálné
-- spojení, jen ne to, na které se někdo ptal. To je horší než chyba.
create table if not exists transport_cache (
  cache_key   text primary key,
  provider    text not null,
  origin_id   uuid references transit_places on delete cascade,
  dest_id     uuid references transit_places on delete cascade,
  -- Začátek okna, na které se ptáme. Uložený proto, aby šlo cache zneplatnit
  -- podle času a ne jen podle TTL.
  window_start timestamptz not null,
  window_end   timestamptz not null,
  payload     jsonb not null,
  fetched_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  hits        int not null default 0
);

create index if not exists transport_cache_expiry_idx
  on transport_cache (expires_at);

alter table transport_cache enable row level security;
-- Cache je serverová. Klient se do ní nedostane ani pro čtení: obsahuje
-- výsledky pro cizí výlety a jediné, co z ní má vidět, je odpověď funkce.
revoke all on transport_cache from authenticated, anon;

-- Počítadlo zásahů. Vlastní funkce proto, že `update ... set hits = hits + 1`
-- přes PostgREST znamená přečíst, přičíst a zapsat ze dvou souběžných
-- požadavků — a pak číslo, které nic neměří.
create or replace function bump_transport_cache(p_key text)
returns void
language sql
security definer
set search_path = public
as $$
  update transport_cache set hits = hits + 1 where cache_key = p_key;
$$;

revoke execute on function bump_transport_cache(text)
  from public, authenticated, anon;

-- Úklid. Bez něj tabulka roste donekonečna a free tier má 500 MB.
select cron.schedule(
  'transport-cache-sweep',
  '17 3 * * *',
  $$delete from transport_cache where expires_at < now() - interval '1 day'$$
);

-- ---------------------------------------------------------------------------
-- 2. Tarifní pravidla
-- ---------------------------------------------------------------------------
-- Odhad, ne ceník, a je to tak označené na každém řádku i na obrazovce.
--
-- Přesné jízdné z veřejné dopravy v ČR nevydává zadarmo nikdo — je to
-- otevřené riziko zapsané v architektuře §22. Alternativa k odhadu není
-- přesná cena, ale žádná cena, a rozpětí s odkazem na oficiální nákup je
-- užitečnější než prázdné místo.
--
-- confidence je to, co UI překládá na „≈" versus „od–do": pravidlo, kterému
-- věříme na desetikoruny, a pravidlo, které jen tipuje řád, nesmí vypadat
-- stejně.
create table if not exists fare_rules (
  id          uuid primary key default gen_random_uuid(),
  provider    text,
  country     char(2) not null default 'CZ',
  region      text,
  mode        stop_mode,
  rule_type   text not null check (rule_type in ('per_km', 'flat', 'zone')),
  -- per_km: cena za kilometr. flat/zone: cena za jízdu.
  min_price   numeric(10, 2) not null,
  max_price   numeric(10, 2) not null,
  currency    char(3) not null default 'CZK',
  -- Minimální a maximální jízdné u per_km. Krátká jízda vlakem nestojí
  -- 2,10 Kč a dlouhá neroste lineárně donekonečna.
  floor_price numeric(10, 2),
  cap_price   numeric(10, 2),
  confidence  text not null default 'rough'
              check (confidence in ('high', 'medium', 'rough')),
  valid_from  date not null default current_date,
  valid_to    date,
  -- Čím vyšší, tím dřív se pravidlo zkusí. Konkrétní přebíjí obecné.
  priority    int not null default 0,
  notes       text,
  constraint fare_range check (max_price >= min_price)
);

alter table fare_rules enable row level security;
revoke all on fare_rules from authenticated, anon;

-- Seed. Řádové odhady k srpnu 2026, ne opsaný ceník — proto rozpětí a
-- proto confidence. Aktualizuje se přepsáním řádku, ne migrací.
insert into fare_rules
  (provider, country, mode, rule_type, min_price, max_price,
   floor_price, cap_price, confidence, priority, notes)
values
  (null, 'CZ', 'train', 'per_km', 1.60, 2.60, 30, 700, 'medium', 10,
   'ČD kilometrické pásmo, rozpětí pokrývá včasnou slevu i plné jízdné.'),
  (null, 'CZ', 'bus',   'per_km', 1.20, 1.90, 25, 500, 'medium', 10,
   'Linkový autobus. Dálkoví dopravci bývají levnější než regionální.'),
  (null, 'CZ', 'tram',       'flat', 20, 40, null, null, 'medium', 20,
   'Městská jízdenka. Zóny se liší, proto rozpětí.'),
  (null, 'CZ', 'trolleybus', 'flat', 20, 40, null, null, 'medium', 20, null),
  (null, 'CZ', 'metro',      'flat', 20, 40, null, null, 'medium', 20, null),
  (null, 'CZ', 'ferry',      'flat', 0,  60, null, null, 'rough',  20,
   'V PID zdarma na jízdenku, jinde samostatné.'),
  (null, 'CZ', 'funicular',  'flat', 0,  80, null, null, 'rough',  20, null),
  (null, 'CZ', 'cablecar',   'flat', 100, 400, null, null, 'rough', 20,
   'Horské lanovky. Rozptyl je obrovský a odhad to musí přiznat.'),
  (null, 'CZ', null, 'per_km', 1.20, 2.60, 25, 700, 'rough', 0,
   'Poslední záchrana, když druh dopravy neznáme.')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 3. Konfigurace poskytovatelů
-- ---------------------------------------------------------------------------
-- URL v app_config, ne v kódu: přepnutí z komunitní instance na vlastní
-- MOTIS je pak změna řádku v databázi, ne deploy. Stejný vzor jako
-- OPEN_METEO_URL.
--
-- Prázdná hodnota znamená „poskytovatel není nakonfigurovaný" a funkce
-- spadne zpátky na geometrický odhad — ne na chybu. Aplikace musí jet i
-- bez routovacího enginu, protože ho zatím nemá.
insert into app_config (key, value) values
  ('transport_provider',      '"estimate"'::jsonb),
  ('transport_cache_ttl_min', '180'::jsonb),
  -- Pěší dostupnost zastávky. Nad tuhle vzdálenost už to není přestup.
  ('transport_max_walk_m',    '1200'::jsonb)
on conflict (key) do nothing;

comment on table transport_cache is
  'Serverová cache odpovědí vyhledávače spojení. Klíč nese i časové okno — '
  'bez něj by cache vracela reálné spojení mimo dotaz.';
