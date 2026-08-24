-- ============================================================================
-- M8, první polovina — plán výletu jako časová osa, kterou jde upravovat.
--
-- Doteď byla záložka „Plán" jenom odhad vzdálenosti a ceny: dvě karty, žádný
-- čas, nic, co by se dalo posunout. Tahle migrace zavádí stav, který
-- posouvání přežije — architektura §9.5 (`itineraries` + `itinerary_items`),
-- rozšířený o tři sloupce, bez kterých se replanning nedá dělat poctivě:
--
--   source       odkud položka je (engine / poskytovatel / uživatel)
--   is_locked    tohle engine nesmí sáhnout
--   user_edited  tohle už člověk jednou posunul rukou
--
-- Bez nich je po znovunačtení výletu plán jenom seznam časů a engine nemá jak
-- poznat, co si uživatel vybral sám. To je celý rozdíl mezi „vygenerovaný
-- itinerář" a „pracovní plocha".
--
-- CO SE TU **NEUKLÁDÁ**: odpověď Transitousu. Ani syrová, ani „skoro syrová".
-- V `detail` je náš vlastní model spoje (linka, zastávky, časy) — tedy to, co
-- z normalizace vyleze, ne to, co do ní vlezlo. Výměna poskytovatele pak
-- neznamená migraci dat.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Slovník
-- ---------------------------------------------------------------------------
-- Enumy, ne text s checkem: druh položky se čte v každém dotazu a v každém
-- mapování na klientovi, a překlep v `check` se pozná až za běhu.
do $$ begin
  create type plan_item_kind as enum (
    'transport',      -- jízda spojem
    'walk',           -- pěší úsek
    'transfer',       -- čekání na přestup
    'activity',       -- to, kvůli čemu se jede
    'free',           -- volný program
    'meal',
    'accommodation',
    'custom'          -- co si přidal uživatel
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type plan_item_source as enum (
    'generated',      -- engine, smí se přepočítat
    'provider',       -- konkrétní spoj z vyhledávače, engine ho smí vyměnit
    'user_selected',  -- spoj, který si vybral člověk — vyměnit jen s upozorněním
    'user_created'    -- položka, kterou člověk založil
  );
exception when duplicate_object then null;
end $$;

-- Která část výletu to je. Tohle je to, co dělá „přepočítej jenom cestu zpět"
-- levnou operací místo prohledávání celého plánu.
do $$ begin
  create type plan_segment as enum ('outbound', 'stay', 'return');
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Plán
-- ---------------------------------------------------------------------------
create table if not exists itineraries (
  id            uuid primary key default gen_random_uuid(),
  trip_id       uuid not null references trips on delete cascade,
  variant       text not null default 'primary'
                check (variant in ('primary', 'alternative', 'plan_b')),
  -- Den, na který plán je. Odvozený ze zamčeného termínu v zóně výletu, ne
  -- z `now()` — plán se dá otevřít i z jiného časového pásma.
  plan_date     date,

  -- Constraints, jak je vyslovil uživatel. Nejsou to výsledky, jsou to zadání:
  -- „chci dorazit do 12:00" musí přežít i replanning, který ho nesplnil,
  -- protože jinak by se příště hledalo podle něčeho jiného, než co člověk řekl.
  depart_after  timestamptz,
  arrive_by     timestamptz,
  home_by       timestamptz,

  -- Kdo dodal jízdní řád a jestli vůbec nějaký byl. `has_timetable = false`
  -- znamená, že časy jsou geometrický odhad — UI to musí říct nahlas.
  provider      text,
  has_timetable boolean not null default false,

  warnings      jsonb not null default '[]'::jsonb,
  mode          text not null default 'engine' check (mode in ('engine', 'ai')),
  generated_by  text,

  -- Optimistický zámek. Plán je sdílený a upravovat ho může kterýkoli člen;
  -- bez revize by pomalejší telefon tiše přepsal cizí změnu vlastní starší
  -- kopií a nikdo by se to nedozvěděl.
  revision      int not null default 0,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (trip_id, variant)
);

create index if not exists itineraries_trip_idx on itineraries (trip_id);

drop trigger if exists itineraries_updated on itineraries;
create trigger itineraries_updated before update on itineraries
  for each row execute function set_updated_at();

comment on table itineraries is
  'Časová osa výletu. Jeden řádek na variantu; primary je ta, kterou vidí '
  'záložka Plán.';

-- ---------------------------------------------------------------------------
-- 3. Položky
-- ---------------------------------------------------------------------------
create table if not exists itinerary_items (
  id            uuid primary key default gen_random_uuid(),
  itinerary_id  uuid not null references itineraries on delete cascade,
  seq           int not null,

  kind          plan_item_kind not null,
  segment       plan_segment not null default 'stay',

  starts_at     timestamptz not null,
  ends_at       timestamptz not null,

  -- Klíč a parametry, ne hotová věta (§9.5). Čeština potřebuje ICU a věta
  -- ve sloupci se nedá přeložit ani přeskloňovat.
  title_key     text not null,
  title_params  jsonb not null default '{}'::jsonb,

  -- Náš model spoje, ne odpověď poskytovatele. U jízdy: linka, dopravce,
  -- nástupiště, ID spoje. U aktivity: poznámka. Schválně jsonb — tvar se
  -- mezi druhy položek liší a šestnáct nullable sloupců by bylo horší.
  detail        jsonb not null default '{}'::jsonb,

  from_name     text,
  to_name       text,
  place_id      uuid references transit_places on delete set null,

  cost_min      numeric(10, 2),
  cost_max      numeric(10, 2),
  currency      char(3) not null default 'CZK',
  -- 'exact' smí být jen to, co přišlo z důvěryhodného zdroje jako přesná
  -- hodnota. U jízdného v ČR to zatím neumí nikdo, takže tam bude 'estimated'.
  confidence    text not null default 'estimated'
                check (confidence in ('exact', 'estimated', 'rough')),

  source        plan_item_source not null default 'generated',
  is_locked     boolean not null default false,
  user_edited   boolean not null default false,

  created_at    timestamptz not null default now(),

  unique (itinerary_id, seq),
  constraint itinerary_items_range check (ends_at >= starts_at)
);

create index if not exists itinerary_items_order_idx
  on itinerary_items (itinerary_id, seq);

comment on column itinerary_items.is_locked is
  'Engine tuhle položku nesmí posunout. Zamyká ji uživatel, nebo vznikne '
  'zamčená (rezervovaná aktivita, ručně vybraný spoj).';

-- ---------------------------------------------------------------------------
-- 4. RLS
-- ---------------------------------------------------------------------------
-- Čtení přes politiku, zápis výhradně přes RPC níž. Kdyby klient mohl psát
-- přímo, byla by „výměna položek plánu" několik nezávislých requestů a plán
-- by šel zastihnout v půlce.
alter table itineraries enable row level security;
alter table itinerary_items enable row level security;

drop policy if exists itineraries_read on itineraries;
create policy itineraries_read on itineraries
  for select using (is_trip_member(trip_id));

drop policy if exists itinerary_items_read on itinerary_items;
create policy itinerary_items_read on itinerary_items
  for select using (
    exists (
      select 1 from itineraries i
      where i.id = itinerary_items.itinerary_id and is_trip_member(i.trip_id)
    )
  );

grant select on itineraries, itinerary_items to authenticated;
revoke insert, update, delete on itineraries from authenticated, anon;
revoke insert, update, delete on itinerary_items from authenticated, anon;

-- ---------------------------------------------------------------------------
-- 5. Čtení plánu
-- ---------------------------------------------------------------------------
-- Jeden jsonb dokument, ne dvě sady řádků. Plán se čte celý nebo vůbec —
-- položka bez hlavičky nedává smysl a dva dotazy by znamenaly, že se mezi
-- nimi dá trefit do jiné revize.
--
-- Místní časy jdou ven jako text bez zóny, stejně jako u `trip_candidates_local`.
-- Klient nemá tz databázi a `toLocal()` na zařízení v UTC posune celý plán
-- o dvě hodiny — což je přesně ta chyba, kterou opravovala migrace
-- 20260821140000.
create or replace function trip_plan(p_trip uuid, p_variant text default 'primary')
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_tz   text;
  v_it   itineraries%rowtype;
  v_out  jsonb;
begin
  if not is_trip_member(p_trip) then
    return null;
  end if;

  select timezone into v_tz from trips where id = p_trip;
  if v_tz is null then
    return null;
  end if;

  select * into v_it
  from itineraries
  where trip_id = p_trip and variant = p_variant;

  if not found then
    return null;                    -- žádný plán ještě není; to není chyba
  end if;

  select jsonb_build_object(
    'id',            v_it.id,
    'trip_id',       v_it.trip_id,
    'variant',       v_it.variant,
    'plan_date',     v_it.plan_date,
    'depart_after',  v_it.depart_after,
    'arrive_by',     v_it.arrive_by,
    'home_by',       v_it.home_by,
    'provider',      v_it.provider,
    'has_timetable', v_it.has_timetable,
    'warnings',      v_it.warnings,
    'mode',          v_it.mode,
    'revision',      v_it.revision,
    'timezone',      v_tz,
    'items',         coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'id',           i.id,
                   'seq',          i.seq,
                   'kind',         i.kind,
                   'segment',      i.segment,
                   'starts_at',    i.starts_at,
                   'ends_at',      i.ends_at,
                   -- ISO bez zóny: 2026-09-12T08:25:00
                   'local_starts_at',
                     to_char(i.starts_at at time zone v_tz, 'YYYY-MM-DD"T"HH24:MI:SS'),
                   'local_ends_at',
                     to_char(i.ends_at at time zone v_tz, 'YYYY-MM-DD"T"HH24:MI:SS'),
                   'title_key',    i.title_key,
                   'title_params', i.title_params,
                   'detail',       i.detail,
                   'from_name',    i.from_name,
                   'to_name',      i.to_name,
                   'place_id',     i.place_id,
                   'cost_min',     i.cost_min,
                   'cost_max',     i.cost_max,
                   'currency',     i.currency,
                   'confidence',   i.confidence,
                   'source',       i.source,
                   'is_locked',    i.is_locked,
                   'user_edited',  i.user_edited
                 )
                 order by i.seq
               )
        from itinerary_items i
        where i.itinerary_id = v_it.id
      ),
      '[]'::jsonb
    )
  ) into v_out;

  return v_out;
end;
$$;

grant execute on function trip_plan(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Zápis plánu
-- ---------------------------------------------------------------------------
-- Celý plán najednou, v jedné transakci. Replanning mění několik položek
-- současně a částečně uložený plán by byl horší než neuložený: časová osa,
-- kde nová cesta zpět navazuje na starou aktivitu, vypadá platně.
--
-- Nemaže a nezakládá znovu bez rozmyslu — položky, které si klient posílá
-- s vlastním ID, si ID podrží. Kdyby se ID měnila při každém uložení,
-- „co se změnilo" by po reloadu bylo vždycky „všechno".
--
-- p_revision je optimistický zámek. NULL znamená „vím, že zakládám", což
-- klient posílá jenom u prvního uložení.
create or replace function save_trip_plan(
  p_trip     uuid,
  p_plan     jsonb,
  p_revision int default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_variant text := coalesce(p_plan ->> 'variant', 'primary');
  v_id      uuid;
  v_current int;
  v_item    jsonb;
  v_seq     int := 0;
  v_keep    uuid[] := '{}';
  v_item_id uuid;
begin
  if not is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;

  select id, revision into v_id, v_current
  from itineraries
  where trip_id = p_trip and variant = v_variant
  for update;

  if v_id is null then
    insert into itineraries (
      trip_id, variant, plan_date, depart_after, arrive_by, home_by,
      provider, has_timetable, warnings, generated_by, revision
    )
    values (
      p_trip,
      v_variant,
      nullif(p_plan ->> 'plan_date', '')::date,
      nullif(p_plan ->> 'depart_after', '')::timestamptz,
      nullif(p_plan ->> 'arrive_by', '')::timestamptz,
      nullif(p_plan ->> 'home_by', '')::timestamptz,
      nullif(p_plan ->> 'provider', ''),
      coalesce((p_plan ->> 'has_timetable')::boolean, false),
      coalesce(p_plan -> 'warnings', '[]'::jsonb),
      nullif(p_plan ->> 'generated_by', ''),
      1
    )
    returning id into v_id;
  else
    -- Vlastní SQLSTATE, ne generická chyba: klient na tomhle jediném případu
    -- nemá zkoušet znovu, má znovu načíst. 40001 by si spletl s deadlockem.
    if p_revision is not null and p_revision <> v_current then
      raise exception
        'plan was modified by somebody else (have %, got %)', v_current, p_revision
        using errcode = 'P0409';
    end if;

    update itineraries
       set plan_date     = nullif(p_plan ->> 'plan_date', '')::date,
           depart_after  = nullif(p_plan ->> 'depart_after', '')::timestamptz,
           arrive_by     = nullif(p_plan ->> 'arrive_by', '')::timestamptz,
           home_by       = nullif(p_plan ->> 'home_by', '')::timestamptz,
           provider      = nullif(p_plan ->> 'provider', ''),
           has_timetable = coalesce((p_plan ->> 'has_timetable')::boolean, false),
           warnings      = coalesce(p_plan -> 'warnings', '[]'::jsonb),
           generated_by  = nullif(p_plan ->> 'generated_by', ''),
           revision      = v_current + 1
     where id = v_id;
  end if;

  -- Nejdřív se uvolní celé pořadí. Bez toho naráží `unique (itinerary_id, seq)`
  -- na položky, které v novém plánu ještě mají svoje staré seq -- a to nastane
  -- pokaždé, když replanning nějakou položku ubere.
  update itinerary_items set seq = -1000 - seq where itinerary_id = v_id;

  for v_item in select * from jsonb_array_elements(coalesce(p_plan -> 'items', '[]'::jsonb))
  loop
    v_item_id := nullif(v_item ->> 'id', '')::uuid;

    insert into itinerary_items (
      id, itinerary_id, seq, kind, segment, starts_at, ends_at,
      title_key, title_params, detail, from_name, to_name, place_id,
      cost_min, cost_max, currency, confidence, source, is_locked, user_edited
    )
    values (
      coalesce(v_item_id, gen_random_uuid()),
      v_id,
      v_seq,
      (v_item ->> 'kind')::plan_item_kind,
      coalesce((v_item ->> 'segment')::plan_segment, 'stay'),
      (v_item ->> 'starts_at')::timestamptz,
      (v_item ->> 'ends_at')::timestamptz,
      v_item ->> 'title_key',
      coalesce(v_item -> 'title_params', '{}'::jsonb),
      coalesce(v_item -> 'detail', '{}'::jsonb),
      nullif(v_item ->> 'from_name', ''),
      nullif(v_item ->> 'to_name', ''),
      nullif(v_item ->> 'place_id', '')::uuid,
      nullif(v_item ->> 'cost_min', '')::numeric,
      nullif(v_item ->> 'cost_max', '')::numeric,
      coalesce(nullif(v_item ->> 'currency', ''), 'CZK'),
      coalesce(nullif(v_item ->> 'confidence', ''), 'estimated'),
      coalesce((v_item ->> 'source')::plan_item_source, 'generated'),
      coalesce((v_item ->> 'is_locked')::boolean, false),
      coalesce((v_item ->> 'user_edited')::boolean, false)
    )
    on conflict (id) do update
      set seq          = excluded.seq,
          kind         = excluded.kind,
          segment      = excluded.segment,
          starts_at    = excluded.starts_at,
          ends_at      = excluded.ends_at,
          title_key    = excluded.title_key,
          title_params = excluded.title_params,
          detail       = excluded.detail,
          from_name    = excluded.from_name,
          to_name      = excluded.to_name,
          place_id     = excluded.place_id,
          cost_min     = excluded.cost_min,
          cost_max     = excluded.cost_max,
          currency     = excluded.currency,
          confidence   = excluded.confidence,
          source       = excluded.source,
          is_locked    = excluded.is_locked,
          user_edited  = excluded.user_edited;

    v_keep := v_keep || coalesce(v_item_id, (select id from itinerary_items
                                              where itinerary_id = v_id and seq = v_seq));
    v_seq := v_seq + 1;
  end loop;

  -- Co klient neposlal, uživatel smazal.
  delete from itinerary_items
   where itinerary_id = v_id and not (id = any (v_keep));

  return trip_plan(p_trip, v_variant);
end;
$$;

grant execute on function save_trip_plan(uuid, jsonb, int) to authenticated;

comment on function save_trip_plan is
  'Nahradí celý plán v jedné transakci a vrátí ho zpátky i s novou revizí. '
  'SQLSTATE P0409 znamená, že plán mezitím změnil někdo jiný.';

-- ---------------------------------------------------------------------------
-- 7. Smazání plánu
-- ---------------------------------------------------------------------------
-- Používá se, když se odemkne termín: plán bez data je plán na den, který
-- neplatí, a nechat ho viset je horší než ho zahodit.
create or replace function reset_trip_plan(p_trip uuid, p_variant text default 'primary')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;
  delete from itineraries where trip_id = p_trip and variant = p_variant;
end;
$$;

grant execute on function reset_trip_plan(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Konfigurace poskytovatele spojení
-- ---------------------------------------------------------------------------
-- POZOR — LICENCE. Transitous je komunitní hostovaný MOTIS **bez komerční
-- licence** (TRANSIT_DATA.md §5 a registr nákladů C1). Je tu proto, aby se
-- proti němu dalo vyvíjet a testovat; do produkce patří vlastní instance
-- MOTISu (software je MIT). `transport_provider` proto zůstává 'estimate' —
-- zapnutí Transitousu je vědomé rozhodnutí jednoho `update`, ne výchozí stav.
--
-- Transitous navíc vyžaduje dvě věci, které nejsou volitelné:
--   * User-Agent s názvem aplikace, verzí a kontaktem
--   * viditelný odkaz na https://transitous.org/sources/
-- Obojí drží tahle konfigurace, aby se to nedalo zapnout a zapomenout.
insert into app_config (key, value) values
  ('transitous_url',       '"https://api.transitous.org"'::jsonb),
  -- Cesta k plánovači je verzovaná (/api/v6/plan). Edge Function si při 404
  -- sáhne po starších verzích a najdenou si zapamatuje do konce běhu.
  ('motis_api_version',    '"v6"'::jsonb),
  ('transport_user_agent',
   '"PlanTo/0.1 (+https://planto.app; kontakt@planto.app)"'::jsonb),
  ('transport_attribution',
   '"Spojení: Transitous (transitous.org/sources) · data OpenStreetMap a dopravců"'::jsonb),
  -- Kolik minut navíc si nechat na přestup nad rámec toho, co spočítal
  -- vyhledávač. Nula znamená „věř jízdnímu řádu", což na nádraží nefunguje.
  ('plan_transfer_buffer_min', '5'::jsonb),
  -- Cesta z domova na první zastávku, dokud nemáme adresu uživatele.
  ('plan_home_walk_min',       '10'::jsonb)
on conflict (key) do nothing;

comment on table itinerary_items is
  'Položky časové osy. detail nese NÁŠ model spoje, nikdy odpověď '
  'poskytovatele — výměna Transitous → vlastní MOTIS nesmí být migrace dat.';

-- ---------------------------------------------------------------------------
-- 9. Fakta, na kterých plán stojí
-- ---------------------------------------------------------------------------
-- Jedno volání místo pěti. Engine potřebuje vědět odkud, kam, který den, jak
-- dlouhý ten den je a kolik lidí jede — a hlavně **posun časové zóny výletu**.
--
-- Ten posun je tu z jednoho konkrétního důvodu: klient nemá tz databázi.
-- Kdyby si „den začíná v 7:00" přeložil na okamžik podle zóny telefonu,
-- hledal by na emulátoru v UTC spoj na devátou. Zóna výletu je jediná
-- správná odpověď a spočítat ji umí jenom Postgres, který tu databázi má.
create or replace function trip_plan_context(p_trip uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  t            trips%rowtype;
  v_date       date;
  v_local      timestamp;
  v_offset_min int;
  v_people     int;
  v_dest_lat   double precision;
  v_dest_lon   double precision;
  v_dest_name  text;
  v_dest_place uuid;
  v_buffer     int;
  v_walk       int;
begin
  if not is_trip_member(p_trip) then
    return null;
  end if;

  select * into t from trips where id = p_trip;
  if not found then
    return null;
  end if;

  -- Den výletu je první den zamčeného termínu, v zóně výletu. Bez zámku plán
  -- nedává smysl: nemá na kdy být.
  v_date := (lower(t.locked_range) at time zone t.timezone)::date;

  if v_date is not null then
    v_local := (v_date + t.day_start)::timestamp;
    -- Naivní místní čas minus tentýž okamžik vyjádřený v UTC = posun zóny.
    v_offset_min := round(
      extract(epoch from (v_local - ((v_local at time zone t.timezone)
                                      at time zone 'UTC'))) / 60
    )::int;
  end if;

  select greatest(1, count(*))::int into v_people
  from trip_participants p
  where p.trip_id = p_trip and p.status <> 'declined';

  -- Kurátorovaná destinace přebíjí volný cíl, stejně jako v _trip_weather_point.
  -- Dvě odpovědi na „kam se jede" by znamenaly, že plán měří vzdálenost jinam,
  -- než kde počítá počasí.
  -- Přes tabulku, ne přes proměnnou v FROM. Kurátorovaná destinace přebíjí
  -- volný cíl — stejně jako v _trip_weather_point. Dvě odpovědi na „kam se
  -- jede" by znamenaly, že plán měří vzdálenost jinam, než kde se počítá
  -- počasí, a obojí by vypadalo správně.
  select
    coalesce(st_y(d.point::geometry), st_y(tr.destination_point::geometry)),
    coalesce(st_x(d.point::geometry), st_x(tr.destination_point::geometry)),
    coalesce(d.name, tr.destination_free)
  into v_dest_lat, v_dest_lon, v_dest_name
  from trips tr
  left join destinations d on d.id = tr.destination_id
  where tr.id = p_trip;

  v_dest_place := t.destination_place_id;

  select (value #>> '{}')::int into v_buffer
  from app_config where key = 'plan_transfer_buffer_min';
  select (value #>> '{}')::int into v_walk
  from app_config where key = 'plan_home_walk_min';

  return jsonb_build_object(
    'trip_id',   t.id,
    'timezone',  t.timezone,
    'plan_date', v_date,
    'zone_offset_minutes', v_offset_min,
    -- left(...::text, 5), ne to_char(): to_char() nemá overload pro `time`
    -- a spadlo by až za běhu, na produkční instanci.
    'day_start', left(t.day_start::text, 5),
    'day_end',   left(t.day_end::text, 5),
    'group_size', v_people,
    'transfer_buffer_min', coalesce(v_buffer, 5),
    'home_walk_min',       coalesce(v_walk, 10),
    'origin', jsonb_build_object(
      'place_id', t.origin_place_id,
      'name',     t.origin_label,
      'lat',      st_y(t.origin_point::geometry),
      'lon',      st_x(t.origin_point::geometry)
    ),
    -- Null, dokud cíl nemá polohu. Jméno bez souřadnic není místo a plán se
    -- z něj postavit nedá — obrazovka na to má vlastní stav.
    'destination', case
      when v_dest_lat is null or v_dest_lon is null then null
      else jsonb_build_object(
        'place_id', v_dest_place,
        'name',     coalesce(v_dest_name, 'Cíl'),
        'lat',      v_dest_lat,
        'lon',      v_dest_lon
      )
    end
  );
end;
$$;

grant execute on function trip_plan_context(uuid) to authenticated;

comment on function trip_plan_context is
  'Vstupy pro plánovací engine v jednom volání, včetně posunu časové zóny '
  'výletu — ten klient sám spočítat neumí a bez něj hledá spoje o dvě '
  'hodiny vedle.';
