-- ============================================================================
-- M7, druhá polovina — kolik to bude stát.
--
-- CO TAHLE FUNKCE JE A CO NENÍ
--
-- Je to model, ne ceník. Doprava jde z transport_options(), která sama nemá
-- jízdní řád; jídlo je celostátní průměr; vstupné existuje jen u cílů z
-- tabulky destinations, která je zatím prázdná. Každá položka proto nese
-- confidence a UI to musí ukázat.
--
-- Návrhový princip (architektura §1.5): "≈ 240 Kč (odhad)" je lepší než
-- sebejistě špatných "238 Kč". Proto se všechno vrací jako rozpětí min–max a
-- proto tu je řádek 'accommodation' bez čísel — nocleh do modelu nepatří až
-- do V1, ale u dvoudenního výletu je to největší položka a tvářit se, že
-- neexistuje, by z celého součtu udělalo lež.
--
-- Všechna čísla jsou NA OSOBU. transport_options() už palivo dělí počtem lidí
-- v autě, takže obě dopravy jsou srovnatelné a nic se tu nedělí podruhé.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Vstupy, které se mění bez migrace
-- ---------------------------------------------------------------------------
-- Denní sazba za jídlo je široká schválně: spodní hranice je student s
-- rohlíky v batohu, horní je oběd v restauraci a káva. Zúžit ji by znamenalo
-- tvrdit něco, co o téhle skupině nevíme.
insert into app_config (key, value) values
  ('food_czk_per_day_min', '150'::jsonb),
  ('food_czk_per_day_max', '450'::jsonb),
  ('cost_buffer_min_pct',  '0.10'::jsonb),
  ('cost_buffer_max_pct',  '0.20'::jsonb)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Rozpad nákladů
-- ---------------------------------------------------------------------------
create or replace function estimate_trip_cost(p_trip uuid)
returns table (
  kind       text,
  min_czk    numeric,
  max_czk    numeric,
  confidence text
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  t            trips%rowtype;
  v_days       int;
  v_food_min   numeric;
  v_food_max   numeric;
  v_buf_min    numeric;
  v_buf_max    numeric;
  v_tr_min     numeric;
  v_tr_max     numeric;
  v_entry      numeric;
  v_sum_min    numeric := 0;
  v_sum_max    numeric := 0;
begin
  select * into t from trips where id = p_trip;
  if not found or not is_trip_member(p_trip) then
    return;                     -- nečlen nedostane řádky, ne chybu
  end if;

  -- Bez cíle se nevrací nic, ani jídlo a rezerva. Doprava je u výletu tímhle
  -- směrem obvykle největší položka, takže součet bez ní není neúplný odhad —
  -- je to jiné číslo, které vypadá jako odhad. Stejné chování jako
  -- transport_options(), takže obě záložky mlčí ve stejnou chvíli.
  if t.destination_point is null and t.destination_id is null then
    return;
  end if;

  v_days := greatest(coalesce(t.duration_days, 1), 1);

  select (value #>> '{}')::numeric into v_food_min
  from app_config where key = 'food_czk_per_day_min';
  select (value #>> '{}')::numeric into v_food_max
  from app_config where key = 'food_czk_per_day_max';
  select (value #>> '{}')::numeric into v_buf_min
  from app_config where key = 'cost_buffer_min_pct';
  select (value #>> '{}')::numeric into v_buf_max
  from app_config where key = 'cost_buffer_max_pct';

  -- ---- doprava -----------------------------------------------------------
  -- Z nabízených možností ta nejlevnější podle středu rozpětí. Sečíst obě by
  -- znamenalo účtovat cestu dvakrát; vzít min jedné a max druhé by vyrobilo
  -- rozpětí, které neodpovídá žádné skutečné cestě.
  select o.cost_min_czk, o.cost_max_czk
    into v_tr_min, v_tr_max
  from transport_options(p_trip) o
  order by (o.cost_min_czk + o.cost_max_czk) / 2
  limit 1;

  if v_tr_min is not null then
    kind := 'transport'; min_czk := v_tr_min; max_czk := v_tr_max;
    confidence := 'estimate';
    v_sum_min := v_sum_min + v_tr_min;
    v_sum_max := v_sum_max + v_tr_max;
    return next;
  end if;

  -- ---- vstupné -----------------------------------------------------------
  -- Jen u cíle z tabulky destinations. Volně zadaný cíl žádné vstupné nezná a
  -- vymyslet ho nelze — proto se řádek neobjeví, místo aby ukázal nulu.
  -- (Nula by tvrdila "vstup zdarma", což je jiné tvrzení než "nevíme".)
  if t.destination_id is not null then
    select entrance_fee into v_entry from destinations where id = t.destination_id;
    if coalesce(v_entry, 0) > 0 then
      kind := 'entry'; min_czk := v_entry; max_czk := v_entry;
      confidence := 'known';
      v_sum_min := v_sum_min + v_entry;
      v_sum_max := v_sum_max + v_entry;
      return next;
    end if;
  end if;

  -- ---- jídlo -------------------------------------------------------------
  kind := 'food';
  min_czk := round(v_food_min * v_days, 0);
  max_czk := round(v_food_max * v_days, 0);
  confidence := 'estimate';
  v_sum_min := v_sum_min + min_czk;
  v_sum_max := v_sum_max + max_czk;
  return next;

  -- ---- nocleh ------------------------------------------------------------
  -- Bez čísel, ale s řádkem. Ubytování je V1 (architektura §16) a u
  -- vícedenního výletu je to největší položka rozpočtu. Součet, který ji tiše
  -- vynechá, je horší než součet, který přizná, že ji neumí.
  if v_days > 1 then
    kind := 'accommodation'; min_czk := null; max_czk := null;
    confidence := 'unknown';
    return next;
  end if;

  -- ---- rezerva -----------------------------------------------------------
  -- Na to, co model nezná: kafe navíc, lanovka, autobus, který nejel.
  kind := 'buffer';
  min_czk := round(v_sum_min * v_buf_min, 0);
  max_czk := round(v_sum_max * v_buf_max, 0);
  confidence := 'estimate';
  return next;
end;
$$;

comment on function estimate_trip_cost is
  'Rozpad nákladů na osobu, vždy jako rozpětí. Řádek s confidence = unknown '
  'znamena "tuhle polozku model neumi", ne "je zdarma".';

grant execute on function estimate_trip_cost(uuid) to authenticated;
