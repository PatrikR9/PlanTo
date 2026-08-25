-- M15b: vícedenní výlet a čas na místě jako zadání
--
-- Dvě věci, které se ukázaly až na skutečném výletu na dva dny:
--
-- 1. Plán stavěl celý výlet na první den termínu. Cesta zpět tím vycházela
--    večer prvního dne — u dvoudenního výletu nesmysl. Kontext proto vrací
--    i poslední den termínu a cesta zpět se hledá na něj.
--
-- 2. „Jak dlouho chceme být na místě" bylo jen odvozené číslo, které se
--    nedalo říct. Teď je to zadání jako každé jiné (`leave_at`) a přežije
--    přepočet, který ho nesplnil — jinak by se příště hledalo podle něčeho
--    jiného, než co člověk řekl.

alter table itineraries
  add column if not exists leave_at timestamptz;

comment on column itineraries.leave_at is
  'Kdy chce skupina vyrazit zpátky. Zadání uživatele, ne výsledek — proto '
  'stojí vedle depart_after/arrive_by/home_by a ne v itinerary_items.';

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
    'leave_at',      v_it.leave_at,
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
      leave_at, provider, has_timetable, warnings, generated_by, revision
    )
    values (
      p_trip,
      v_variant,
      nullif(p_plan ->> 'plan_date', '')::date,
      nullif(p_plan ->> 'depart_after', '')::timestamptz,
      nullif(p_plan ->> 'arrive_by', '')::timestamptz,
      nullif(p_plan ->> 'home_by', '')::timestamptz,
      nullif(p_plan ->> 'leave_at', '')::timestamptz,
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
           leave_at      = nullif(p_plan ->> 'leave_at', '')::timestamptz,
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
  v_last       date;
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

  -- Poslední den termínu. `locked_range` je polouzavřený, takže horní mez
  -- ukazuje na první okamžik PO výletu: u dvoudenního výletu je to půlnoc
  -- třetího dne. Odečtení mikrosekundy z toho udělá poslední okamžik uvnitř
  -- termínu, což platí i pro hodinový režim, kde rozsah končí v 17:00.
  v_last := (
    ((upper(t.locked_range) - interval '1 microsecond') at time zone t.timezone)
  )::date;
  if v_last is null or v_last < v_date then
    v_last := v_date;
  end if;

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
    -- Den návratu. U jednodenního výletu je to týž den; u vícedenního je
    -- to den, na který se hledá cesta zpět. Bez toho by plán posadil
    -- skupinu na večerní spoj domů první den.
    'return_date', v_last,
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
