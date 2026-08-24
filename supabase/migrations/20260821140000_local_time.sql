-- ============================================================================
-- Termíny v zóně výletu, ne v zóně telefonu.
--
-- Chyba, kterou to opravuje: v denním režimu je `starts_at` půlnoc v zóně
-- výletu, tedy u nás 22:00 UTC předchozího dne. Klient dělal
-- `DateTime.parse(...).toLocal()` — a na zařízení, které běží v UTC (výchozí
-- nastavení emulátoru Androidu), z toho vyšel **předchozí den**. Karta pak
-- tvrdila „Pátek 14. 8." o bloku, který začíná v sobotu, a nesouhlasila
-- s pruhem dnů — ten dostává holé datum `2026-08-15` a neposune se.
--
-- Naměřeno 21. 8. na reálných datech:
--   2026-08-14T22:00:00+00:00  =  so 15. 8. v Praze  =  5/5
--   2026-08-13T22:00:00+00:00  =  pá 14. 8. v Praze  =  4/5
-- Aplikace ukazovala „Pátek 14. 8. … 5 z 5", tedy sobotní blok pod pátečním
-- datem. Na obrazovce, kde se vybírá termín, je to špatné datum, ne kosmetika.
--
-- Řešení: server dodá i **místní** čas jako text bez zóny. `starts_at`
-- zůstává tím, čím byl — identitou pro hlasování a zámek — a k zobrazení
-- slouží nové sloupce. Klient tak nemusí znát pravidla časových zón, což bez
-- balíčku s tz databází ani neumí.
--
-- Obálka, ne přepis: `trip_candidates` je dvousetřádková funkce se dvěma
-- větvemi a počasím. Kopírovat ji kvůli třem sloupcům by znamenalo mít dvě
-- místa, kde žije ranking.
--
-- Apply with: supabase db push
-- ============================================================================

create or replace function trip_candidates_local(
  p_trip  uuid,
  p_limit int default 20
)
returns table (
  starts_at            timestamptz,
  ends_at              timestamptz,
  window_ends_at       timestamptz,
  free_count           int,
  total_count          int,
  free_user_ids        uuid[],
  busy_user_ids        uuid[],
  is_weekend           boolean,
  is_holiday           boolean,
  score                numeric,
  yes_count            int,
  maybe_count          int,
  no_count             int,
  my_vote              text,
  is_locked            boolean,
  weather_score        int,
  weather_code         int,
  temp_max             numeric,
  precip_prob          int,
  wind_gust_kmh        numeric,
  sunrise              timestamptz,
  sunset               timestamptz,
  -- ISO bez zóny. Klient je parsuje jako naivní místní čas a nic nepřepočítá.
  local_starts_at      text,
  local_ends_at        text,
  local_window_ends_at text
)
language sql
security definer
set search_path = public
stable
as $$
  select c.*,
         to_char(c.starts_at      at time zone t.timezone,
                 'YYYY-MM-DD"T"HH24:MI:SS'),
         to_char(c.ends_at        at time zone t.timezone,
                 'YYYY-MM-DD"T"HH24:MI:SS'),
         to_char(c.window_ends_at at time zone t.timezone,
                 'YYYY-MM-DD"T"HH24:MI:SS')
  from trip_candidates(p_trip, p_limit) c
  cross join trips t
  where t.id = p_trip;
$$;

comment on function trip_candidates_local is
  'trip_candidates plus místní čas výletu jako text. starts_at zůstává '
  'identitou pro hlasování; local_* slouží k zobrazení.';

grant execute on function trip_candidates_local(uuid, int)
  to authenticated, anon;

-- Totéž pro sloty jednoho dne. Tady je posun méně nápadný — den je zadaný
-- parametrem — ale hodina by se na UTC zařízení ukázala o dvě dřív, než jak
-- ji nabízí mřížka, která se kreslí z day_start klienta.
create or replace function trip_day_slots_local(p_trip uuid, p_day date)
returns table (
  starts_at       timestamptz,
  ends_at         timestamptz,
  free_count      int,
  total_count     int,
  free_user_ids   uuid[],
  busy_user_ids   uuid[],
  is_weekend      boolean,
  is_holiday      boolean,
  score           numeric,
  yes_count       int,
  maybe_count     int,
  no_count        int,
  my_vote         text,
  is_locked       boolean,
  local_starts_at text,
  local_ends_at   text
)
language sql
security definer
set search_path = public
stable
as $$
  select s.*,
         to_char(s.starts_at at time zone t.timezone,
                 'YYYY-MM-DD"T"HH24:MI:SS'),
         to_char(s.ends_at   at time zone t.timezone,
                 'YYYY-MM-DD"T"HH24:MI:SS')
  from trip_day_slots(p_trip, p_day) s
  cross join trips t
  where t.id = p_trip;
$$;

comment on function trip_day_slots_local is
  'trip_day_slots plus místní čas výletu jako text.';

grant execute on function trip_day_slots_local(uuid, date)
  to authenticated, anon;
