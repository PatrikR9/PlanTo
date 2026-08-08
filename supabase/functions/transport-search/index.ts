// transport/search — jak se dostat z A do B a jaké jsou možnosti.
//
// Tohle je celá odpovědnost M7. Ne „jaký bude výlet" — to řeší M8, která si
// tuhle funkci zavolá a z odpovědi si vybere. Odpověď je proto stabilní JSON
// bez ohledu na to, který poskytovatel ji naplnil.
//
//   request → auth → validace → cache → poskytovatel → normalizace
//           → tarif → ranking → cache → odpověď
//
// PROČ EDGE FUNCTION A NE VOLÁNÍ Z FLUTTERU
// Klient nikdy nemluví s třetí stranou. Tím je „v aplikaci nejsou žádné
// klíče" strukturální vlastnost, ne slib, který si někdo pamatuje. Navíc
// cache i rate limit musí být sdílené — pětičlenná skupina otevírající jednu
// obrazovku jinak vyrobí pět stejných dotazů.
//
// POSKYTOVATELÉ
//   estimate  geometrie + tarifní model. Výchozí, nic nestojí, nemá jízdní
//             řád. Je to současný stav produktu a zůstává jako fallback.
//   motis     skutečné spojení. Zapne se přepsáním app_config.
//             transport_provider — komunitní Transitous NENÍ komerčně
//             licencovaný, takže do produkce patří jenom vlastní instance.
//   ors       auto. Bez klíče se auto počítá geometricky jako dosud.
//
// Volba je v databázi a ne v kódu schválně: přepnutí na vlastní MOTIS je pak
// změna jednoho řádku, ne deploy.
//
// Deploy with: supabase functions deploy transport-search

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  cacheKey,
  estimateCo2,
  estimateFare,
  type FareRule,
  idosLink,
  minutesBetween,
  normaliseMotis,
  rank,
  type TransportLeg,
  type TransportMode,
  type TransportOption,
} from "../_shared/transport.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function fail(code: string, message: string, status: number, retryable = false) {
  // Kód, ne věta. Klient si hlášku složí sám ve svém jazyce — server
  // neposílá text, který by se dostal na obrazovku (architektura §12.3).
  return json({ error: { code, message, retryable } }, status);
}

const MAX_HORIZON_DAYS = 60;
const MAX_PAST_HOURS = 2;

interface Body {
  origin?: { placeId?: string; lat?: number; lon?: number; name?: string };
  destination?: { placeId?: string; lat?: number; lon?: number; name?: string };
  departure?: string;
  arriveBy?: boolean;
  modes?: TransportMode[];
  groupSize?: number;
  tripId?: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") {
    return fail("METHOD_NOT_ALLOWED", "POST only", 405);
  }

  const auth = req.headers.get("Authorization");
  if (!auth) return fail("UNAUTHORIZED", "missing bearer token", 401);

  // Dvojice klientů schválně. `user` ověřuje, kdo se ptá, a čte přes RLS;
  // `admin` sahá na cache a tarify, které klientská role nevidí. Kdyby stačil
  // jeden, byl by to service_role na všechno — a pak by chyba ve validaci
  // znamenala přístup k cizím výletům.
  const url = Deno.env.get("SUPABASE_URL")!;
  const user = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: me } = await user.auth.getUser();
  if (!me?.user) return fail("UNAUTHORIZED", "invalid token", 401);

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return fail("BAD_REQUEST", "body is not JSON", 400);
  }

  // --- validace ------------------------------------------------------------
  // Neověřený vstup se nikdy nedostane do dotazu ani do URL poskytovatele.
  const origin = await resolvePlace(user, body.origin);
  const dest = await resolvePlace(user, body.destination);
  if (!origin) return fail("INVALID_ORIGIN", "origin is missing or unknown", 400);
  if (!dest) return fail("INVALID_DESTINATION", "destination is missing or unknown", 400);

  const when = body.departure ? Date.parse(body.departure) : Date.now();
  if (!Number.isFinite(when)) {
    return fail("INVALID_DATETIME", "departure is not a valid instant", 400);
  }
  // Minulost nemá jízdní řád, na který by se dalo nastoupit. Dvě hodiny
  // tolerance kvůli tomu, že výlet se plánuje v průběhu dne a hodina zpátky
  // je pořád „dneska ráno", ne chyba.
  if (when < Date.now() - MAX_PAST_HOURS * 3600_000) {
    return fail("DEPARTURE_IN_THE_PAST", "departure is in the past", 400);
  }
  if (when > Date.now() + MAX_HORIZON_DAYS * 86400_000) {
    return fail(
      "DEPARTURE_TOO_FAR",
      `no timetable exists more than ${MAX_HORIZON_DAYS} days ahead`,
      400,
    );
  }

  const modes: TransportMode[] = Array.isArray(body.modes) && body.modes.length
    ? body.modes.filter((m) => typeof m === "string").slice(0, 12)
    : ["train", "bus", "tram", "metro", "trolleybus", "walk"];
  const groupSize = clamp(Number(body.groupSize ?? 1), 1, 20);
  const arriveBy = body.arriveBy === true;
  const windowStart = new Date(when).toISOString();

  // --- konfigurace ---------------------------------------------------------
  const cfg = await config(admin);
  const provider = String(cfg.transport_provider ?? "estimate");
  const ttlMin = Number(cfg.transport_cache_ttl_min ?? 180);

  const key = cacheKey({
    provider,
    originId: origin.id,
    originLat: origin.lat,
    originLon: origin.lon,
    destId: dest.id,
    destLat: dest.lat,
    destLon: dest.lon,
    windowStart,
    arriveBy,
    modes,
  });

  // --- cache ---------------------------------------------------------------
  const { data: cached } = await admin
    .from("transport_cache")
    .select("payload, expires_at")
    .eq("cache_key", key)
    .maybeSingle();

  if (cached && Date.parse(cached.expires_at) > Date.now()) {
    // Počítadlo zásahů je jediný způsob, jak zjistit, jestli má cache smysl.
    // Chyba při jeho zvýšení nesmí shodit odpověď, kterou už máme.
    admin.rpc("bump_transport_cache", { p_key: key }).then(
      () => {},
      () => {},
    );
    return json({ ...cached.payload, cached: true });
  }

  // --- poskytovatel --------------------------------------------------------
  let options: TransportOption[] = [];
  let usedProvider = provider;
  try {
    if (provider === "motis") {
      options = await viaMotis(origin, dest, windowStart, arriveBy, modes);
    }
  } catch (e) {
    // Výpadek poskytovatele degraduje na odhad, nespadne. Obrazovka pak
    // ukáže totéž, co ukazovala před M7 — což je kompletní, ne rozbité.
    console.error("motis failed, falling back to estimate", e);
    options = [];
  }

  if (options.length === 0) {
    usedProvider = "estimate";
    options = geometricEstimate(origin, dest, windowStart, groupSize);
  }

  // --- tarif, CO2, odkazy --------------------------------------------------
  const { data: ruleRows } = await admin
    .from("fare_rules")
    .select(
      "mode, rule_type, min_price, max_price, currency, floor_price, cap_price, confidence, priority",
    )
    .lte("valid_from", new Date().toISOString().slice(0, 10))
    .or(`valid_to.is.null,valid_to.gte.${new Date().toISOString().slice(0, 10)}`);
  const rules = (ruleRows ?? []) as FareRule[];

  for (const o of options) {
    o.fare ??= estimateFare(o.legs, rules);
    o.co2Kg ??= estimateCo2(o.legs);
    o.deepLink ??= idosLink(origin.name, dest.name, o.departure);
  }

  const ranked = rank(options, { groupSize });

  const payload = {
    origin,
    destination: dest,
    searched_at: new Date().toISOString(),
    provider: usedProvider,
    // Jasně řečené na úrovni odpovědi, ne jen u ceny: bez jízdního řádu
    // nejsou odhad jen peníze, ale i časy.
    has_timetable: usedProvider === "motis",
    options: ranked.options.map(serialise),
    picks: {
      best: ranked.best,
      cheapest: ranked.cheapest,
      fastest: ranked.fastest,
      fewest_transfers: ranked.fewestTransfers,
    },
    cached: false,
  };

  // Zápis do cache nesmí zdržet odpověď ani ji shodit.
  const expires = new Date(Date.now() + ttlMin * 60_000).toISOString();
  admin
    .from("transport_cache")
    .upsert({
      cache_key: key,
      provider: usedProvider,
      origin_id: origin.id,
      dest_id: dest.id,
      window_start: windowStart,
      window_end: new Date(when + 6 * 3600_000).toISOString(),
      payload,
      expires_at: expires,
      fetched_at: new Date().toISOString(),
    })
    .then(() => {}, (e: unknown) => console.error("cache write failed", e));

  return json(payload);
});

// ---------------------------------------------------------------------------
// Vstupy
// ---------------------------------------------------------------------------

interface Resolved {
  id: string | null;
  name: string;
  lat: number;
  lon: number;
}

/** ID zastávky vyhrává nad poslanými souřadnicemi.
 *
 *  Klient smí poslat obojí, ale věří se ID: souřadnice jsou v požadavku
 *  proto, aby šlo hledat i k místu, které v databázi zastávek není (chata,
 *  rozcestník), ne proto, aby si klient mohl přepsat, kde zastávka leží.
 */
async function resolvePlace(
  client: ReturnType<typeof createClient>,
  input: Body["origin"],
): Promise<Resolved | null> {
  if (!input) return null;
  if (typeof input.placeId === "string" && UUID.test(input.placeId)) {
    const { data } = await client.rpc("transit_place", { p_id: input.placeId });
    const row = Array.isArray(data) ? data[0] : null;
    if (row) {
      return {
        id: row.id,
        name: row.name,
        lat: Number(row.lat),
        lon: Number(row.lon),
      };
    }
    return null;
  }
  const lat = Number(input.lat);
  const lon = Number(input.lon);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
  return {
    id: null,
    name: String(input.name ?? "").slice(0, 120) || `${lat}, ${lon}`,
    lat,
    lon,
  };
}

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function config(
  admin: ReturnType<typeof createClient>,
): Promise<Record<string, unknown>> {
  const { data } = await admin
    .from("app_config")
    .select("key, value")
    .in("key", [
      "transport_provider",
      "transport_cache_ttl_min",
      "transport_max_walk_m",
    ]);
  const out: Record<string, unknown> = {};
  for (const r of data ?? []) out[(r as { key: string }).key] = (r as { value: unknown }).value;
  return out;
}

function clamp(n: number, lo: number, hi: number): number {
  return Number.isFinite(n) ? Math.min(Math.max(n, lo), hi) : lo;
}

// ---------------------------------------------------------------------------
// MOTIS
// ---------------------------------------------------------------------------

/** Vyhledání přes MOTIS.
 *
 *  URL a případný token jsou v prostředí funkce, nikdy v aplikaci. Bez URL
 *  se sem vůbec nedojde — app_config.transport_provider zůstane 'estimate'.
 *
 *  Psáno proti dokumentaci MOTIS v2, neověřeno proti běžící instanci.
 *  Normalizace je proto defenzivní a výpadek degraduje na odhad; první běh
 *  proti vlastní instanci to potvrdí nebo opraví.
 */
async function viaMotis(
  origin: Resolved,
  dest: Resolved,
  when: string,
  arriveBy: boolean,
  modes: TransportMode[],
): Promise<TransportOption[]> {
  const base = Deno.env.get("MOTIS_URL");
  if (!base) throw new Error("MOTIS_URL is not set");

  const u = new URL("/api/v1/plan", base);
  u.searchParams.set("fromPlace", `${origin.lat},${origin.lon}`);
  u.searchParams.set("toPlace", `${dest.lat},${dest.lon}`);
  u.searchParams.set("time", when);
  u.searchParams.set("arriveBy", String(arriveBy));
  u.searchParams.set("numItineraries", "5");
  u.searchParams.set(
    "transitModes",
    modes.filter((m) => m !== "walk").map(motisModeName).join(","),
  );

  const headers: Record<string, string> = { Accept: "application/json" };
  const token = Deno.env.get("MOTIS_TOKEN");
  if (token) headers.Authorization = `Bearer ${token}`;

  // Timeout je povinný. Bez něj visí Edge Function na cizí nedostupné
  // službě až do vlastního limitu a uživatel kouká na točící se kolečko.
  const res = await fetch(u, {
    headers,
    signal: AbortSignal.timeout(12_000),
  });
  if (!res.ok) throw new Error(`MOTIS ${res.status}`);
  return normaliseMotis(await res.json());
}

function motisModeName(m: TransportMode): string {
  switch (m) {
    case "train":
      return "RAIL";
    case "metro":
      return "SUBWAY";
    case "tram":
      return "TRAM";
    case "trolleybus":
      return "TROLLEYBUS";
    case "bus":
      return "BUS";
    case "ferry":
      return "FERRY";
    default:
      return "TRANSIT";
  }
}

// ---------------------------------------------------------------------------
// Geometrický odhad
// ---------------------------------------------------------------------------

/** To, co produkt umí bez jízdního řádu.
 *
 *  Je to stejný model jako v transport_options() a schválně: dokud nemáme
 *  vlastní MOTIS, tohle je pravda o produktu a mít dvě různá čísla na dvou
 *  obrazovkách by bylo horší než mít jedno přiznaně hrubé.
 *
 *  Čas odjezdu se nevymýšlí. Leg dostane požadovaný začátek okna a v
 *  odpovědi je has_timetable: false — „odjezd 7:14", který není vlak, je
 *  jediné číslo, podle kterého by se někdo zařídil.
 */
function geometricEstimate(
  origin: Resolved,
  dest: Resolved,
  when: string,
  _groupSize: number,
): TransportOption[] {
  const crow = haversineKm(origin.lat, origin.lon, dest.lat, dest.lon);
  if (crow < 0.2) return [];

  const railKm = crow * 1.20;
  const speed = railKm < 30 ? 28 : railKm < 100 ? 55 : 75;
  const minutes = Math.round(15 + (railKm / speed) * 60);
  const dep = new Date(Date.parse(when));
  const arr = new Date(dep.getTime() + minutes * 60_000);

  const leg: TransportLeg = {
    mode: "train",
    operatorName: null,
    lineName: null,
    headsign: null,
    fromName: origin.name,
    toName: dest.name,
    fromStopId: origin.id,
    toStopId: dest.id,
    departure: dep.toISOString(),
    arrival: arr.toISOString(),
    durationMinutes: minutes,
    distanceMeters: Math.round(railKm * 1000),
    platform: null,
    tripId: null,
    routeId: null,
    intermediateStops: null,
  };

  return [
    {
      id: `estimate|public|${Math.round(railKm)}`,
      mode: "train",
      departure: leg.departure,
      arrival: leg.arrival,
      durationMinutes: minutesBetween(leg.departure, leg.arrival),
      transfers: 0,
      walkMinutes: 0,
      legs: [leg],
      fare: null,
      co2Kg: null,
      deepLink: null,
      ranking: { score: 0, reasonCodes: [] },
    },
  ];
}

function haversineKm(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const R = 6371;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

// ---------------------------------------------------------------------------
// Serializace
// ---------------------------------------------------------------------------

// snake_case ven, camelCase uvnitř. Odpověď je kontrakt s Flutterem i s M8 a
// drží se konvence zbytku API; překlad na jednom místě je levnější než
// dvojí pojmenování v celém souboru.
function serialise(o: TransportOption) {
  return {
    id: o.id,
    mode: o.mode,
    departure: o.departure,
    arrival: o.arrival,
    duration_minutes: o.durationMinutes,
    transfers: o.transfers,
    walk_minutes: o.walkMinutes,
    legs: o.legs.map((l) => ({
      mode: l.mode,
      operator: l.operatorName,
      line: l.lineName,
      headsign: l.headsign,
      from: l.fromName,
      to: l.toName,
      from_stop_id: l.fromStopId,
      to_stop_id: l.toStopId,
      departure: l.departure,
      arrival: l.arrival,
      duration_minutes: l.durationMinutes,
      distance_meters: l.distanceMeters,
      platform: l.platform,
      trip_id: l.tripId,
      route_id: l.routeId,
      intermediate_stops: l.intermediateStops,
    })),
    fare: o.fare && {
      min: o.fare.min,
      max: o.fare.max,
      currency: o.fare.currency,
      confidence: o.fare.confidence,
      is_estimate: true,
      basis: o.fare.basis,
    },
    co2_kg: o.co2Kg,
    deep_link: o.deepLink,
    ranking: { score: o.ranking.score, reason_codes: o.ranking.reasonCodes },
  };
}
