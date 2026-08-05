-- ============================================================================
-- M8, první polovina — co si vzít.
--
-- PROČ PRAVIDLA A NE MODEL
--
-- "Prší v sobotu odpoledne, vezmi si pláštěnku" je rozhodnutí, které musí
-- dopadnout pokaždé stejně, dát se otestovat a nestát nic. To je definice
-- pravidla, ne promptu. AI k tomuhle seznamu přidává až věci, které pravidla
-- neznají, a to je placená vrstva (architektura §11.2) — free tier tady
-- nesmí sáhnout na LLM ani omylem.
--
-- Každá položka nese důvod, proč tam je. Seznam bez důvodů je seznam, kterému
-- se nedá věřit ani odporovat: uživatel neví, jestli je pláštěnka tam kvůli
-- předpovědi nebo protože ji tam appka dává vždycky, a tak ji buď bere vždy,
-- nebo nikdy. Reason_key + params, ne hotová věta — čeština potřebuje ICU.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Pravidlo
-- ---------------------------------------------------------------------------
-- Každý predikát je nullable a null znamená "nezajímá mě". Pravidlo se
-- uplatní, když sedí VŠECHNY jeho vyplněné predikáty — konjunkce, ne skóre.
-- Skóre by znamenalo, že hraniční pravidlo někdy projde a někdy ne, což je u
-- seznamu na sbalení to nejhorší chování: nepředvídatelný seznam se přestane
-- kontrolovat.
create table if not exists packing_rules (
  id             uuid primary key default gen_random_uuid(),

  -- L10n klíč, ne text. V DB nikdy nestojí hotová věta.
  item_key       text not null,
  category       text not null check (category in
                   ('clothing','gear','documents','food','safety')),
  -- 1 = bez tohohle nejezdi, 2 = doporučeno, 3 = když se vejde
  priority       int  not null default 2 check (priority between 1 and 3),
  reason_key     text not null,

  -- --- predikáty ---
  -- Trip má ALESPOŇ JEDEN z těchhle tagů. Prázdné pole = na tagech nezáleží.
  activity_tags  text[] not null default '{}',
  transport      transport_pref[] not null default '{}',

  min_days       int,
  max_days       int,

  -- Počasí zamčeného (nebo nejlépe hodnoceného) dne.
  min_temp       numeric,   -- pocitové maximum je NAD tímhle
  max_temp       numeric,   -- … nebo POD tímhle
  min_precip_prob int,
  min_precip_mm  numeric,
  min_wind_gust  numeric,
  min_snow_cm    numeric,
  min_uv         numeric,

  -- Aktivita by končila po setmění. Počítá se ze sunset a délky slotu.
  needs_darkness boolean not null default false,

  months         int[] not null default '{}',

  created_at     timestamptz not null default now()
);

create index if not exists packing_rules_tags_idx
  on packing_rules using gin (activity_tags);

alter table packing_rules enable row level security;

-- Pravidla nejsou tajemství a čtou se při každém otevření záložky. Zápis je
-- jen service_role: tohle je kurátorovaný obsah, ne uživatelská data.
drop policy if exists packing_rules_read on packing_rules;
create policy packing_rules_read on packing_rules for select using (true);
grant select on packing_rules to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Co je odškrtnuté
-- ---------------------------------------------------------------------------
-- Vlastní stav, ne skupinový. "Kdo veze lékárničku" je dělba věcí ve skupině a
-- to je samostatná featura (V2) — udělat z tohohle napůl sdílený seznam by
-- znamenalo, že odškrtnutí jednoho člověka schová položku ostatním.
create table if not exists packing_checked (
  trip_id  uuid not null references trips on delete cascade,
  user_id  uuid not null references profiles on delete cascade,
  item_key text not null,
  primary key (trip_id, user_id, item_key)
);

alter table packing_checked enable row level security;

drop policy if exists packing_checked_own on packing_checked;
create policy packing_checked_own on packing_checked
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, delete on packing_checked to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Sestavení seznamu
-- ---------------------------------------------------------------------------
-- Počasí se bere ze zamčeného termínu, a když žádný není, z nejlépe
-- hodnoceného kandidáta. Bez obojího se seznam pořád sestaví — jen bez
-- pravidel závislých na počasí, protože "nevíme" nesmí znamenat "hezky".
-- Tohle je stejné rozhodnutí jako u _weather_score, který vrací null místo
-- 100: chybějící data nesmí nikdy vypadat jako dobrá zpráva.
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

  -- Který den se balí na. Zamčený termín vyhrává; jinak nejlepší návrh.
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

    -- Vrátí se za tmy? Půl hodiny rezervy, protože soumrak není okamžik.
    if w.sunset is not null and t.slot_minutes is not null
       and t.locked_range is not null then
      v_dark := upper(t.locked_range) > w.sunset - interval '30 minutes';
    end if;
  end if;

  return query
  select
    r.item_key,
    r.category,
    r.priority,
    r.reason_key,
    exists (
      select 1 from packing_checked pc
      where pc.trip_id = p_trip
        and pc.user_id = auth.uid()
        and pc.item_key = r.item_key
    ),
    -- Aby obrazovka poznala, které položky zmizí, když se změní termín.
    (r.min_temp is not null or r.max_temp is not null
      or r.min_precip_prob is not null or r.min_precip_mm is not null
      or r.min_wind_gust is not null or r.min_snow_cm is not null
      or r.min_uv is not null or r.needs_darkness)
  from packing_rules r
  where
    -- aktivity
    (cardinality(r.activity_tags) = 0 or r.activity_tags && t.activity_tags)
    -- doprava
    and (cardinality(r.transport) = 0 or t.transport = any(r.transport))
    -- délka
    and (r.min_days is null or coalesce(t.duration_days, 1) >= r.min_days)
    and (r.max_days is null or coalesce(t.duration_days, 1) <= r.max_days)
    -- měsíc
    and (cardinality(r.months) = 0 or v_month = any(r.months))
    -- počasí: bez předpovědi se pravidlo na počasí NEUPLATNÍ
    and (r.min_temp        is null or w.apparent_max  >= r.min_temp)
    and (r.max_temp        is null or w.apparent_max  <= r.max_temp)
    and (r.min_precip_prob is null or w.precip_prob   >= r.min_precip_prob)
    and (r.min_precip_mm   is null or w.precip_mm     >= r.min_precip_mm)
    and (r.min_wind_gust   is null or w.wind_gust_kmh >= r.min_wind_gust)
    and (r.min_snow_cm     is null or w.snowfall_cm   >= r.min_snow_cm)
    and (r.min_uv          is null or w.uv_index      >= r.min_uv)
    and (not r.needs_darkness or v_dark)
  order by r.priority, r.category, r.item_key;
end;
$$;

comment on function build_packing_list is
  'Deterministický seznam na sbalení. Žádné AI: stejný vstup dává vždy stejný '
  'seznam, jde otestovat a stojí nula. AI v M9 jen přidává, co pravidla neznají.';

grant execute on function build_packing_list(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Odškrtávání
-- ---------------------------------------------------------------------------
-- RPC místo přímého insert/delete, aby se členství kontrolovalo na serveru a
-- aby obrazovka volala jednu věc místo dvou podle směru.
create or replace function set_packing_checked(
  p_trip uuid, p_item text, p_checked boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;

  if p_checked then
    insert into packing_checked (trip_id, user_id, item_key)
    values (p_trip, auth.uid(), p_item)
    on conflict do nothing;
  else
    delete from packing_checked
    where trip_id = p_trip and user_id = auth.uid() and item_key = p_item;
  end if;
end;
$$;

grant execute on function set_packing_checked(uuid, text, boolean) to authenticated;
