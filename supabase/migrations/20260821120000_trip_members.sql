-- ============================================================================
-- Kdo je ve výletu, jménem.
--
-- Přehled výletu do teď uměl jen počty: „3 z 3 sdílelo dostupnost". To je
-- odpověď na otázku „můžeme už plánovat", ale ne na tu, kterou má organizátor
-- doopravdy — „na koho ještě čekám". Bez jména se nedá nikoho pobídnout a
-- skupina čeká na anonymní číslo.
--
-- Proč RPC a ne select z klienta: `profiles` je pod RLS a nikdo nesmí číst
-- profily cizích lidí jen proto, že zná jejich user_id. Členství ve stejném
-- výletu je jediný důvod, proč tahle jména smí být vidět, a ta podmínka patří
-- na server.
--
-- Apply with: supabase db push
-- ============================================================================

create or replace function trip_members(p_trip uuid)
returns table (
  user_id         uuid,
  display_name    text,
  calendar_shared boolean,
  is_organiser    boolean,
  is_me           boolean
)
language sql
security definer
set search_path = public
stable
as $$
  -- is_trip_member je tu, ne v RLS: funkce je security definer, takže RLS na
  -- profiles i trip_participants obchází z definice. Kdo smí číst, musí si
  -- proto rozhodnout sama — stejné pravidlo jako u ical_sync_request.
  select
    tp.user_id,
    p.display_name,
    tp.calendar_shared,
    tp.role = 'organiser',
    tp.user_id = auth.uid()
  from trip_participants tp
  join profiles p on p.id = tp.user_id
  where tp.trip_id = p_trip
    and is_trip_member(p_trip)
    -- Kdo odmítl, ve skupině není a v seznamu nemá co dělat; kdyby tam byl,
    -- počítal by se očima do „na koho čekáme".
    and tp.status <> 'declined'
  order by
    (tp.role = 'organiser') desc,
    -- Kdo ještě nesdílel, patří nahoru: to je ten seznam, kvůli kterému se
    -- na obrazovku kouká.
    tp.calendar_shared,
    p.display_name;
$$;

comment on function trip_members is
  'Členové výletu se jménem a stavem sdílení dostupnosti. Security definer; '
  'členství se kontroluje uvnitř přes is_trip_member.';

-- Anon taky: pozvaný host je plnohodnotný účastník a tenhle seznam je to
-- první, co po připojení uvidí.
grant execute on function trip_members(uuid) to authenticated, anon;

-- ---------------------------------------------------------------------------
-- Všechny časy jednoho dne, nesloučené.
-- ---------------------------------------------------------------------------
-- `trip_candidates` slučuje po sobě jdoucí sloty se shodnou množinou volných
-- lidí do jednoho návrhu. Je to správné pro přehled — čtrnáctihodinový den při
-- kroku 15 minut by jinak vyrobil 52 skoro stejných karet — ale znamená to, že
-- se z celého volného okna nabídne jen jeho začátek. Kdo chce začít v deset,
-- nemá kam klepnout.
--
-- Tahle funkce vrací jeden řádek na slot pro jediný den. Volá se až po výběru
-- dne, takže cena je jeden dotaz na obrazovku, ne na výlet.
--
-- Proč to nejde dopočítat v klientovi: hlasy i zámek jsou klíčované na
-- `slot_start`. Hlas odevzdaný na odvozený čas by se nikdy nenačetl zpátky,
-- protože `_vote_tally` se joinuje na začátek sloučeného běhu. Tally musí
-- vzniknout tam, kde vznikají sloty.
create or replace function trip_day_slots(p_trip uuid, p_day date)
returns table (
  starts_at     timestamptz,
  ends_at       timestamptz,
  free_count    int,
  total_count   int,
  free_user_ids uuid[],
  busy_user_ids uuid[],
  is_weekend    boolean,
  is_holiday    boolean,
  score         numeric,
  yes_count     int,
  maybe_count   int,
  no_count      int,
  my_vote       text,
  is_locked     boolean
)
language plpgsql
security definer
set search_path = public
stable
as $$
#variable_conflict use_column
declare
  t         trips%rowtype;
  v_slot    interval;
  v_step    interval;
  v_start   timestamptz;
  v_end     timestamptz;
  v_locked  timestamptz;
  v_weekend boolean;
  v_holiday boolean;
begin
  select * into t from trips where id = p_trip;
  if not found or not is_trip_member(p_trip) then
    return;                       -- nečlen dostane nula řádků, ne chybu
  end if;

  -- V denním režimu je „slot" celý den a tahle otázka nedává smysl.
  if t.granularity = 'day' then
    return;
  end if;

  if p_day < lower(t.date_window)::date
     or p_day > upper(t.date_window)::date then
    return;
  end if;

  v_slot    := make_interval(mins => coalesce(t.slot_minutes, 120));
  v_step    := make_interval(mins => t.slot_step_minutes);
  v_start   := (p_day + t.day_start) at time zone t.timezone;
  v_end     := (p_day + t.day_end)   at time zone t.timezone;
  v_locked  := lower(t.locked_range);
  v_weekend := extract(isodow from p_day) >= 6;
  v_holiday := exists (
    select 1 from holidays h where h.date = p_day and h.country = 'CZ'
  );

  -- Aktivita se do dne nevejde. Prázdno je správná odpověď.
  if v_end - v_slot < v_start then
    return;
  end if;

  return query
  with participants as (
    select tp.user_id
    from trip_participants tp
    where tp.trip_id = p_trip and tp.status <> 'declined'
  ),
  busy_by_user as (
    select p.user_id,
           coalesce(range_agg(b.period), '{}'::tstzmultirange) as mr
    from participants p
    left join busy_intervals b
      on b.user_id = p.user_id and b.trip_id = p_trip
    group by p.user_id
  ),
  slots as (
    select s from generate_series(v_start, v_end - v_slot, v_step) s
  ),
  slot_state as (
    select sl.s,
           count(*) filter (
             where not (bu.mr && tstzrange(sl.s, sl.s + v_slot, '[)'))
           )::int as free_count,
           count(*)::int as total_count,
           coalesce(array_agg(bu.user_id order by bu.user_id) filter (
             where not (bu.mr && tstzrange(sl.s, sl.s + v_slot, '[)'))
           ), '{}') as free_ids,
           coalesce(array_agg(bu.user_id order by bu.user_id) filter (
             where bu.mr && tstzrange(sl.s, sl.s + v_slot, '[)')
           ), '{}') as busy_ids
    from slots sl
    cross join busy_by_user bu
    group by sl.s
  )
  select
    ss.s,
    ss.s + v_slot,
    ss.free_count, ss.total_count, ss.free_ids, ss.busy_ids,
    v_weekend, v_holiday,
    _candidate_score(ss.free_count, ss.total_count, v_weekend, v_holiday),
    coalesce(v.yes_count, 0), coalesce(v.maybe_count, 0),
    coalesce(v.no_count, 0), v.my_vote,
    v_locked is not null and v_locked = ss.s
  from slot_state ss
  left join _vote_tally(p_trip) v on v.slot_start = ss.s
  order by ss.s;
end;
$$;

comment on function trip_day_slots is
  'Všechny sloty jednoho dne, nesloučené, s hlasy a zámkem. Jen pro časový '
  'režim. Security definer; členství se kontroluje uvnitř.';

grant execute on function trip_day_slots(uuid, date) to authenticated, anon;
