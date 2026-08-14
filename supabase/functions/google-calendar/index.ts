// Obsazenost z Google Calendar, jedním přihlášením.
//
// Proč to je tady a ne v klientovi: client_secret nesmí opustit server a
// pravidlo „klient nikdy nemluví přímo se třetí stranou" je to, co dělá
// „žádné API klíče v aplikaci" strukturálně pravdivým místo aspirace.
//
// Scope je calendar.freebusy. Ta volba není opatrnost navíc — je to jediný
// způsob, jak slib „nečteme názvy vašich událostí" vynutit na úrovni
// oprávnění. Google při tomhle scope neumí vrátit nic jiného než dvojice
// start/konec, i kdyby si o to funkce řekla.
//
// Deploy:
//   supabase secrets set GOOGLE_CLIENT_ID="..."
//   supabase secrets set GOOGLE_CLIENT_SECRET="..."
//   supabase secrets set ICAL_SECRET="$(openssl rand -base64 32)"   # už existuje
//   supabase functions deploy google-calendar
//
// ICAL_SECRET se sdílí s ical-sync schválně: je to tentýž druh tajemství
// (šifrování cizích credentialů at rest) a dva klíče znamenají dvě rotace,
// z nichž jedna se zapomene.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const FREEBUSY_URL = "https://www.googleapis.com/calendar/v3/freeBusy";
const FREEBUSY_SCOPE = "https://www.googleapis.com/auth/calendar.freebusy";

/** Stejná hrubost jako u zařízení. Viz BusyIntervals.granularity. */
const GRANULARITY_MS = 15 * 60 * 1000;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------- šifrování --
// Kopie z ical-sync. Sdílet ji přes _shared/ by bylo hezčí, ale znamenalo by
// to, že jedna změna mění dvě nasazené funkce naráz — a tahle část se nemění.
async function aesKey(): Promise<CryptoKey> {
  const secret = Deno.env.get("ICAL_SECRET");
  if (!secret) {
    throw new Error(
      'ICAL_SECRET is not set. Run: supabase secrets set ICAL_SECRET="$(openssl rand -base64 32)"',
    );
  }
  const raw = Uint8Array.from(atob(secret), (c) => c.charCodeAt(0));
  if (raw.length !== 32) throw new Error("ICAL_SECRET must be 32 bytes, base64");
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, [
    "encrypt",
    "decrypt",
  ]);
}

async function encrypt(plain: string): Promise<string> {
  const key = await aesKey();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv },
      key,
      new TextEncoder().encode(plain),
    ),
  );
  const joined = new Uint8Array(iv.length + ct.length);
  joined.set(iv);
  joined.set(ct, iv.length);
  return btoa(String.fromCharCode(...joined));
}

async function decrypt(b64: string): Promise<string> {
  const key = await aesKey();
  const joined = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: joined.slice(0, 12) },
    key,
    joined.slice(12),
  );
  return new TextDecoder().decode(plain);
}

// -------------------------------------------------------------------- OAuth --
interface TokenResponse {
  access_token?: string;
  refresh_token?: string;
  id_token?: string;
  scope?: string;
  error?: string;
  error_description?: string;
}

async function tokenRequest(form: Record<string, string>): Promise<TokenResponse> {
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: Deno.env.get("GOOGLE_CLIENT_ID")!,
      client_secret: Deno.env.get("GOOGLE_CLIENT_SECRET")!,
      ...form,
    }),
    signal: AbortSignal.timeout(20000),
  });

  const body = (await res.json()) as TokenResponse;
  if (!res.ok || body.error) {
    // Googlova vlastní hláška. `invalid_grant` znamená odvolaný souhlas a
    // patří na něj „připojte se znovu", ne „zkuste to později".
    throw new Error(body.error_description ?? body.error ?? `Google ${res.status}`);
  }
  return body;
}

/**
 * E-mail z id_tokenu, bez ověřování podpisu.
 *
 * Token přišel přímo z tokenového endpointu Googlu přes HTTPS, takže tady
 * nemá kdo lhát; ověřovat podpis by mělo smysl jedině u tokenu od klienta.
 * Slouží k jediné větě v UI a na nic se podle něj nerozhoduje.
 */
function emailFromIdToken(idToken?: string): string | null {
  if (!idToken) return null;
  try {
    const payload = idToken.split(".")[1];
    const json = atob(payload.replace(/-/g, "+").replace(/_/g, "/"));
    return (JSON.parse(json).email as string) ?? null;
  } catch {
    return null;
  }
}

// ----------------------------------------------------------------- freeBusy --
interface Slot {
  start: string;
  end: string;
}

async function freeBusy(
  accessToken: string,
  timeMin: Date,
  timeMax: Date,
): Promise<Slot[]> {
  const res = await fetch(FREEBUSY_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    // Jen primární kalendář. Vypsat ostatní by znamenalo calendar.readonly,
    // tedy scope, který vidí i názvy událostí — a to je přesně ta výměna,
    // kterou tenhle projekt dělat nechce. Kdo má obsazenost roztaženou po víc
    // kalendářích, má pořád iCal odkaz.
    body: JSON.stringify({
      timeMin: timeMin.toISOString(),
      timeMax: timeMax.toISOString(),
      items: [{ id: "primary" }],
    }),
    signal: AbortSignal.timeout(20000),
  });

  if (!res.ok) {
    throw new Error(`Google Calendar odpověděl ${res.status}.`);
  }

  const body = await res.json();
  const cal = body?.calendars?.primary;
  if (cal?.errors?.length) {
    throw new Error(cal.errors[0]?.reason ?? "Kalendář se nepodařilo přečíst.");
  }
  return (cal?.busy ?? []) as Slot[];
}

/**
 * Ořez na okno, zaokrouhlení ven na 15 minut, sloučení překryvů.
 *
 * Tytéž tři kroky, jaké dělá BusyIntervals.prepare na zařízení, a musí to tak
 * zůstat: kdyby jeden zdroj zaokrouhloval dovnitř, tentýž člověk by podle
 * cesty, kterou se připojil, vycházel jednou volný a jednou zabraný.
 * Zaokrouhluje se ven, protože jediná chyba, která se stát nesmí, je hlásit
 * volno uprostřed schůzky.
 */
function prepare(slots: Slot[], windowStart: Date, windowEnd: Date) {
  const out: { start: Date; end: Date }[] = [];

  for (const s of slots) {
    const rawStart = new Date(s.start);
    const rawEnd = new Date(s.end);
    if (!(rawEnd > rawStart)) continue;

    const start = new Date(
      Math.floor(
        Math.max(rawStart.getTime(), windowStart.getTime()) / GRANULARITY_MS,
      ) * GRANULARITY_MS,
    );
    const end = new Date(
      Math.ceil(
        Math.min(rawEnd.getTime(), windowEnd.getTime()) / GRANULARITY_MS,
      ) * GRANULARITY_MS,
    );
    if (end > start) out.push({ start, end });
  }

  out.sort((a, b) => a.start.getTime() - b.start.getTime());

  const merged: { start: Date; end: Date }[] = [];
  for (const i of out) {
    const last = merged[merged.length - 1];
    // Dotýkající se bloky se slučují taky: 9–10 a 10–11 jsou dvě hodiny
    // nedostupnosti a jeden řádek je menší i pravdivější.
    if (!last || i.start > last.end) {
      merged.push(i);
      continue;
    }
    if (i.end > last.end) last.end = i.end;
  }
  return merged;
}

// ------------------------------------------------------------------ handler --
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "missing authorization" }, 401);

  let body: { trip_id?: string; code?: string; redirect_uri?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "body must be JSON" }, 400);
  }
  const tripId = body.trip_id;
  if (!tripId) return json({ error: "trip_id is required" }, 400);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;

  const asUser = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });

  const { data: me } = await asUser.auth.getUser();
  const userId = me?.user?.id;
  if (!userId) return json({ error: "not authenticated" }, 401);

  // Tatáž RPC jako u iCal: membership guarded, takže tahle funkce nikdy
  // nerozhoduje, kdo smí číst výlet.
  const { data: reqRows, error: reqError } = await asUser.rpc(
    "ical_sync_request",
    { p_trip: tripId },
  );
  if (reqError) return json({ error: reqError.message }, 400);
  const plan = reqRows?.[0];
  if (!plan) return json({ error: "not found" }, 404);

  const windowStart = new Date(plan.window_start);
  const windowEnd = new Date(plan.window_end);

  const asService = createClient(
    supabaseUrl,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // ---- první připojení: výměna kódu za tokeny ----------------------------
  let accessToken: string | null = null;

  if (body.code) {
    if (!body.redirect_uri) {
      return json({ error: "redirect_uri is required with code" }, 400);
    }

    let tokens: TokenResponse;
    try {
      tokens = await tokenRequest({
        grant_type: "authorization_code",
        code: body.code,
        redirect_uri: body.redirect_uri,
      });
    } catch (e) {
      return json({ error: (e as Error).message }, 400);
    }

    // Google smí schválit míň, než se žádalo, a pozná se to až tady. Bez
    // téhle kontroly by se účet uložil jako připojený a první dotaz by spadl
    // na 403 — tedy o obrazovku později, než kde se to dá vysvětlit.
    if (!tokens.scope?.includes(FREEBUSY_SCOPE)) {
      return json({
        error: "Bez přístupu k obsazenosti kalendáře to nepůjde. "
          + "Zkuste to znovu a nechte zaškrtnuté „zobrazit dostupnost“.",
      }, 400);
    }

    // refresh_token přijde jen s access_type=offline a prompt=consent, a
    // u druhého souhlasu téhož účtu už nemusí přijít vůbec. Když nedorazí a
    // účet už uložený máme, není to chyba — starý pořád platí.
    if (tokens.refresh_token) {
      const { error: saveError } = await asService
        .from("google_calendar_accounts")
        .upsert({
          user_id: userId,
          email: emailFromIdToken(tokens.id_token),
          refresh_cipher: await encrypt(tokens.refresh_token),
          scope: tokens.scope,
          connected_at: new Date().toISOString(),
          last_error: null,
        });
      if (saveError) return json({ error: saveError.message }, 500);
    }

    accessToken = tokens.access_token ?? null;
  }

  // ---- opakovaná synchronizace: access token z uloženého refreshe --------
  if (!accessToken) {
    const { data: account } = await asService
      .from("google_calendar_accounts")
      .select("refresh_cipher")
      .eq("user_id", userId)
      .maybeSingle();

    if (!account) {
      return json({ error: "Kalendář Googlu není připojený." }, 400);
    }

    try {
      const tokens = await tokenRequest({
        grant_type: "refresh_token",
        refresh_token: await decrypt(account.refresh_cipher),
      });
      accessToken = tokens.access_token ?? null;
    } catch (e) {
      const message = (e as Error).message;
      await asService
        .from("google_calendar_accounts")
        .update({ last_error: message })
        .eq("user_id", userId);
      // Odvolaný souhlas není chyba serveru a nemá se opakovat: účet je
      // potřeba připojit znovu.
      return json({ error: message, reconnect: true }, 400);
    }
  }

  if (!accessToken) return json({ error: "Google nevrátil token." }, 502);

  // ---- vlastní dotaz -----------------------------------------------------
  let rows: { start: Date; end: Date }[];
  try {
    rows = prepare(
      await freeBusy(accessToken, windowStart, windowEnd),
      windowStart,
      windowEnd,
    );
  } catch (e) {
    const message = (e as Error).message;
    await asService
      .from("google_calendar_accounts")
      .update({ last_error: message })
      .eq("user_id", userId);
    return json({ error: message }, 400);
  }

  // Nahradit, nikdy nepřidávat — stejné pravidlo jako u ruční mřížky, importu
  // ze zařízení i iCal odkazu. Zdroje se pro dvojici (výlet, člověk) vylučují,
  // protože „kalendář říká volno, člověk říká zabráno" nemá správné sloučení.
  const { error: deleteError } = await asService
    .from("busy_intervals")
    .delete()
    .eq("trip_id", tripId)
    .eq("user_id", userId);
  if (deleteError) return json({ error: deleteError.message }, 500);

  if (rows.length > 0) {
    const { error: insertError } = await asService.from("busy_intervals").insert(
      rows.map((b) => ({
        trip_id: tripId,
        user_id: userId,
        period: `[${b.start.toISOString()},${b.end.toISOString()})`,
        is_all_day: false,
        source_kind: "google",
      })),
    );
    if (insertError) return json({ error: insertError.message }, 500);
  }

  await asService
    .from("google_calendar_accounts")
    .update({ last_synced_at: new Date().toISOString(), last_error: null })
    .eq("user_id", userId);

  // Prázdný kalendář je odpověď — „nic mi nebrání" — a ta nejužitečnější.
  // Musí počítat jako sdílení, jinak skupina čeká na někoho, kdo už odpověděl.
  await asService
    .from("trip_participants")
    .update({ calendar_shared: true })
    .eq("trip_id", tripId)
    .eq("user_id", userId);

  return json({ blocks: rows.length });
});
