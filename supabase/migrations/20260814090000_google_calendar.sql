-- ============================================================================
-- M14.1 — kalendář Googlem, jedním klepnutím.
--
-- Čtvrtý zdroj obsazenosti vedle zařízení, ruční mřížky a iCal odkazu. Existuje
-- kvůli prohlížeči: pozvaný, který přijde z odkazu ve skupinovém chatu, nemá
-- žádné API ke kalendáři v zařízení a vkládání tajné iCal adresy je pět kroků
-- v cizí aplikaci. Tohle je jedno přihlášení.
--
-- Scope je `calendar.freebusy`, ne `calendar.readonly`. Vrací výhradně
-- začátky a konce obsazených bloků — žádné názvy, místa ani účastníky. Slib
-- „nikdy nečteme názvy vašich událostí" tím drží na úrovni oprávnění, ne jen
-- na naší disciplíně, přesně jako projekce v planto_calendar.
--
-- Refresh token je credential. Leží tu zašifrovaný a nikdo kromě service role
-- ho nesmí přečíst — stejné pravidlo jako url_cipher u iCal odkazů.
--
-- Apply with: supabase db push
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Čtvrtý zdroj
-- ---------------------------------------------------------------------------
alter table busy_intervals drop constraint if exists busy_intervals_source_kind_check;
alter table busy_intervals
  add constraint busy_intervals_source_kind_check
  check (source_kind in ('calendar', 'manual', 'ical', 'google'));

-- ---------------------------------------------------------------------------
-- 2. Připojený účet
-- ---------------------------------------------------------------------------
create table if not exists google_calendar_accounts (
  user_id        uuid primary key references profiles on delete cascade,

  -- Kvůli jediné větě v UI: „Připojeno jako patrik@gmail.com". Bez ní člověk
  -- se dvěma účty nepozná, který z nich zrovna sdílí, a odpojí ten špatný.
  email          text,

  -- base64(iv || AES-GCM ciphertext). Pro Postgres neprůhledné záměrně.
  refresh_cipher text not null,

  -- Co uživatel doopravdy schválil. Ukládá se, protože Google smí vrátit míň,
  -- než se žádalo, a to se pozná až při prvním dotazu — tehdy už je pozdě.
  scope          text not null,

  connected_at   timestamptz not null default now(),
  last_synced_at timestamptz,

  -- Googlova vlastní slova. „Token byl odvolán" a „překročen limit" chtějí od
  -- uživatele jinou reakci, takže se neslévají do „něco se pokazilo".
  last_error     text
);

alter table google_calendar_accounts enable row level security;

-- Žádná politika. Ne omylem: k téhle tabulce se dostane jen service role
-- uvnitř Edge Function. RLS bez politiky znamená, že authenticated i anon
-- nedostanou nic, a token se tak nemá jak dostat do klienta.
revoke all on google_calendar_accounts from anon, authenticated;

comment on table google_calendar_accounts is
  'Refresh tokeny ke Google Calendar. Čte a zapisuje výhradně Edge Function '
  'google-calendar přes service role; klient vidí jen my_google_calendar().';

-- ---------------------------------------------------------------------------
-- 3. Co o svém účtu smí vědět klient
-- ---------------------------------------------------------------------------
-- Všechno kromě toho jediného pole, na kterém záleží. Stejný tvar jako
-- my_calendar_feeds() — token se nevrací a vracet nebude.
create or replace function my_google_calendar()
returns table (
  email          text,
  connected_at   timestamptz,
  last_synced_at timestamptz,
  last_error     text
)
language sql
security definer
set search_path = public
stable
as $$
  select g.email, g.connected_at, g.last_synced_at, g.last_error
  from google_calendar_accounts g
  where g.user_id = auth.uid();
$$;

-- Okamžité smazání, žádný soft delete, žádná lhůta. Obrazovka o soukromí
-- slibuje přesně tohle.
--
-- Bloky, které účet vyrobil, mizí s ním — na rozdíl od iCal odkazu, kde
-- zůstávají. Rozdíl je záměrný: odpojit odkaz znamená „už to nechci
-- aktualizovat", odpojit účet znamená „už o mně nic nemějte".
create or replace function disconnect_google_calendar()
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

  delete from busy_intervals
   where user_id = v_user and source_kind = 'google';

  delete from google_calendar_accounts where user_id = v_user;
end;
$$;

grant execute on function my_google_calendar()        to authenticated;
grant execute on function disconnect_google_calendar() to authenticated;
