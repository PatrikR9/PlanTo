-- Smaže jednoho uživatele i se vším, co po něm zbylo.
--
-- K čemu to je: vývojová adresa se dá použít jen jednou. Supabase na
-- registraci existujícího e-mailu nevrátí chybu, jen tiše nic neudělá, takže
-- druhý pokus o založení účtu na tutéž adresu skončí nepoužitelným stavem.
-- Když člověk nemá druhou schránku, jediná cesta zpátky je uživatele smazat.
--
-- POZOR: Smazat uživatele v dashboardu tlačítkem NEFUNGUJE, dokud po sobě má
-- výlety. `trips.created_by` má `on delete restrict`, což je záměr — výlet,
-- který zmizí, protože jeho zakladatel smazal účet, by vzal s sebou termíny
-- celé skupiny. Na vývoji to ale znamená, že se musí mazat odspoda.
--
-- NIKDY na produkci.
--
-- Použití: vlož e-mail na řádek s `v_email` a spusť celé v SQL editoru.
--
-- Než spustíš: ověř, že jsi na správném projektu. Název v hlavičce nestačí —
-- aplikace míří na REF `dehgpsnemmemnxbhujai` a ten je vidět v adrese
-- (`/project/<ref>`) nebo v Project Settings → General → Reference ID.
-- Jméno projektu a jeho ref jsou dvě různé věci a zaměnit je znamená smazat
-- uživatele tam, kde nevadil, a nechat ho tam, kde vadí.

do $$
declare
  -- ⬇⬇⬇ SEM E-MAIL ⬇⬇⬇
  v_email  text := 'sem@napis.adresu';

  v_uid    uuid;
  v_trips  int;
begin
  -- Kontroluje se tvar, ne konkrétní řetězec.
  --
  -- První verze porovnávala v_email se zástupným textem — jenže ten stál v
  -- souboru dvakrát, takže „nahradit vše" přepsalo i pojistku a ta pak hlásila
  -- chybu na správně vyplněné adrese. Pojistka, kterou rozbije běžná editace,
  -- je horší než žádná: vypadá, že hlídá, a přitom jen překáží.
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$' then
    raise exception 'Doplň na řádek s v_email skutečnou adresu (je tam "%").',
      v_email;
  end if;

  select id into v_uid from auth.users where email = lower(trim(v_email));

  if v_uid is null then
    raise notice 'Uživatel % neexistuje — není co mazat.', v_email;
    return;
  end if;

  -- Nejdřív výlety, které založil. Kaskáda z trips odklidí účastníky,
  -- pozvánky, hlasy, dostupnost i odškrtané balení.
  select count(*) into v_trips from trips where created_by = v_uid;
  delete from trips where created_by = v_uid;

  -- Teprve teď uživatele. Kaskáda z auth.users odklidí profil a přes něj
  -- členství ve výletech, které založil někdo jiný.
  delete from auth.users where id = v_uid;

  raise notice 'Smazán % (%): % vlastních výletů.', v_email, v_uid, v_trips;
end $$;

-- Kontrola, že je opravdu pryč. Prázdný výsledek je ten správný.
select id, email, created_at, last_sign_in_at
from auth.users
order by created_at desc;
