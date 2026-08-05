-- ============================================================================
-- Zápis busy_intervals výhradně přes RPC.
--
-- CO SE ROZBILO A PROČ TO NEBYLA NÁHODA
--
-- 20260728100100_rls.sql odebírá SELECT na busy_intervals všem rolím, včetně
-- vlastních řádků. To je záměr a je to ta správná volba: skupinovou dostupnost
-- vrací group_free_days() jako počty, nikdy jako intervaly, takže budoucí
-- chyba v SELECT policy nemůže vypustit něčí rozvrh.
--
-- Jenže klient pak nesmí sáhnout na tabulku vůbec — ani na zápis. Postgres
-- vyžaduje SELECT na každý sloupec, jehož hodnotu čte WHERE u DELETE nebo
-- UPDATE. Nahrání kalendáře začíná krokem "smaž moje staré bloky", ten WHERE
-- čte trip_id a user_id, a celý tok spadne na 42501 dřív, než se stihne
-- vložit první řádek. RLS policy busy_write_own je přitom naprosto v pořádku;
-- práva se kontrolují před ní.
--
-- Manuální cesta na to nenarazila, protože ta už přes RPC šla (set_manual_busy
-- v 20260731090000). Cesta z kalendáře zůstala na PostgREST. Tohle je dorovnání,
-- ne nová funkcionalita — a zároveň to dělá z nahrání jednu transakci místo
-- dvou kol po síti, mezi kterými mohl uživatel skončit bez dostupnosti úplně.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Nahrání bloků přečtených ze zařízení
-- ---------------------------------------------------------------------------
-- Tvar prvku pole odpovídá tomu, co už drží BusyInterval na klientovi:
--   {"start":"2026-09-12T07:00:00Z","end":"2026-09-12T09:00:00Z","all_day":false}
--
-- Instanty v UTC, ne datum a čas jako u set_manual_busy. Zařízení už zná
-- skutečné okamžiky událostí i s posunem zóny a opakováním, a převádět je zpět
-- na wall-clock jen proto, aby je server převedl znovu, je přesně ten druh
-- oklikou vzniklé DST chyby, kvůli které opakování řeší Kotlin a ne Dart.
create or replace function set_device_busy(p_trip uuid, p_blocks jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_win  tstzrange;
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  -- security definer obchází RLS z definice, takže členství si funkce musí
  -- ověřit sama. (Past č. 3 v registru.)
  if not is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;

  select date_window into v_win from trips where id = p_trip;

  -- Nahradit, nikdy nepřidávat. Zdroje se vzájemně vylučují: "kalendář říká
  -- volno, člověk říká zabráno" nemá správné sloučení.
  delete from busy_intervals where trip_id = p_trip and user_id = v_user;

  insert into busy_intervals (trip_id, user_id, period, is_all_day, source_kind)
  select p_trip, v_user, r * v_win, coalesce((b ->> 'all_day')::boolean, false),
         'calendar'
  from jsonb_array_elements(coalesce(p_blocks, '[]'::jsonb)) as b
  cross join lateral (
    select tstzrange(
      (b ->> 'start')::timestamptz,
      (b ->> 'end')::timestamptz,
      '[)'
    ) as r
  ) x
  -- Průnik s oknem, ne jen zamítnutí toho, co do něj nespadá. Zařízení sice
  -- ořezává samo, ale server je jediné místo, kde to platí i pro klienta,
  -- který je o verzi pozadu — a rok kalendáře v tabulce, ze které nikdo nikdy
  -- nečte víc než okno výletu, je čistá ztráta.
  where not isempty(r) and r && v_win;

  update trip_participants
     set calendar_shared = true
   where trip_id = p_trip and user_id = v_user;
end;
$$;

comment on function set_device_busy is
  'Nahradí bloky volajícího přečtené ze zařízení. Jediná cesta, kterou smí '
  'klient zapsat do busy_intervals — SELECT na té tabulce nemá nikdo.';

grant execute on function set_device_busy(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Odpojení kalendáře
-- ---------------------------------------------------------------------------
-- Stejný důvod: DELETE s WHERE potřebuje SELECT. Navíc je to jedna transakce —
-- smazat bloky a nechat calendar_shared na true by znamenalo, že skupina čeká
-- na dostupnost, kterou už nikdo nemá.
create or replace function clear_my_busy(p_trip uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not is_trip_member(p_trip) then
    raise exception 'not a member of this trip' using errcode = '42501';
  end if;

  delete from busy_intervals where trip_id = p_trip and user_id = v_user;

  update trip_participants
     set calendar_shared = false
   where trip_id = p_trip and user_id = v_user;
end;
$$;

comment on function clear_my_busy is
  'Okamžité smazání vlastní dostupnosti. Slib z obrazovky s vysvětlením: '
  'odpojení maže data hned, ne při dalším běhu úlohy.';

grant execute on function clear_my_busy(uuid) to authenticated;
