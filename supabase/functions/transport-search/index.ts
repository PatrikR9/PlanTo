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
// obrazovku jinak vyrobí pět stejných dotazů. A hlavně: klient tím nikdy
// nevidí Transitous-specific JSON, takže výměna poskytovatele je práce
// v tomhle souboru a nikde jinde.
//
// POSKYTOVATELÉ
//   estimate   geometrie + tarifní model. Výchozí, nic nestojí, nemá jízdní
//              řád. Je to současný stav produktu a zůstává jako fallback.
//   transitous komunitní hostovaný MOTIS. Skutečné jízdní řády. **NENÍ
//              komerčně licencovaný** (TRANSIT_DATA.md §5) — je to vývojový
//              a testovací poskytovatel, do produkce nepatří. Vyžaduje
//              User-Agent s kontaktem a viditelnou atribuci; obojí drží
//              app_config, aby to nešlo zapnout a zapomenout.
//   motis      vlastní instance MOTISu (software je MIT). Tohle je produkční
//              cíl. Stejné API, jiná URL a případný token z prostředí.
//   ors        auto. Bez klíče se auto počítá geometricky jako dosud.
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
  motisTransitModes,
  normaliseMotis,
  rank,
  type TransportLeg,
  type TransportMode,
  type TransportOption,
  withLocalTimes,
} from "../_shared/transport.ts";

/** Typ klienta supabase-js.
 *
 *  `createClient(url, key)` a `createClient(url, key, options)` vracejí dvě
 *  různé instanciace stejných generik a přiřadit jednu do druhé nejde —
 *  `deno check` to hlásí jako TS2345 na každé pomocné funkci. Funkce níž
 *  o schématu databáze nic nevědí (volají `rpc` a `from` s literály), takže
 *  je pro ně ten typ stejně bez informace.
 *
 *  Až projekt bude mít generovaný `Database` typ, tohle je jediné místo,
 *  kde se doplní.
 */
// deno-lint-ignore no-explicit-any
type Db = any;

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
const DEFAULT_TZ = "Europe/Prague";

/** Verze plánovacího endpointu MOTISu, na které se povedlo dovolat.
 *
 *  MOTIS verzuje cestu (/api/v6/plan) a Transitous běží na tom, co zrovna
 *  nasadili. Zapamatovat si funkční verzi po dobu života isolate ušetří dva
 *  zbytečné 404 na každý dotaz; přežít restart nemusí.
 */
let discoveredVersion: string | null = null;

/** Odzhora dolů. Novější první — starší verze vracejí stejná pole, jen jich
 *  mají míň, a normalizace je defenzivní právě proto. */
const MOTIS_VERSIONS = ["v6", "v5", "v4", "v3", "v2", "v1"];

interface Body {
  origin?: { placeId?: string; lat?: number; lon?: number; name?: string };
  destination?: { placeId?: string; lat?: number; lon?: number; name?: string };
  departure?: string;
  arriveBy?: boolean;
  modes?: TransportMode[];
  groupSize?: number;
  tripId?: string;
  /** 'outbound' | 'return'. Neovlivňuje vyhledání, ale je v klíči do cache a
   *  v odpovědi — cesta zpět musí být samostatný dotaz, ne obrácená cesta tam,
   *  a tohle je to, co dělá tu samostatnost viditelnou. */
  direction?: string;
  numItineraries?: number;
  maxTransfers?: number;
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
  const direction = body.direction === "return" ? "return" : "outbound";
  const numItineraries = clamp(Number(body.numItineraries ?? 5), 1, 10);
  const maxTransfers = Number.isFinite(Number(body.maxTransfers))
    ? clamp(Number(body.maxTransfers), 0, 6)
    : null;
  const windowStart = new Date(when).toISOString();

  // Zóna výletu, ne zóna serveru. Bez ní by místní časy v odpovědi byly UTC
  // a klient by je zobrazil o dvě hodiny vedle — přesně chyba, kterou
  // opravovala migrace 20260821140000.
  const tz = await tripTimezone(user, body.tripId);

  // --- konfigurace ---------------------------------------------------------
  const cfg = await config(admin);
  const provider = String(cfg.transport_provider ?? "estimate");
  const ttlMin = Number(cfg.transport_cache_ttl_min ?? 180);
  const attribution = cfg.transport_attribution == null
    ? null
    : String(cfg.transport_attribution);

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
    direction,
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
  let providerError: string | null = null;

  try {
    if (provider === "transitous" || provider === "motis") {
      options = await viaMotisApi(provider, cfg, {
        origin,
        dest,
        when: windowStart,
        arriveBy,
        modes,
        numItineraries,
        maxTransfers,
      });
    }
  } catch (e) {
    // Výpadek poskytovatele degraduje na odhad, nespadne. Obrazovka pak
    // ukáže totéž, co ukazovala před M7 — což je kompletní, ne rozbité.
    // Důvod jde ale do odpovědi: „časy jsou odhad" je jiná věta než „časy
    // jsou odhad, protože vyhledávač neodpověděl", a uživatel má právo znát
    // tu druhou.
    console.error("transit provider failed, falling back to estimate", e);
    providerError = e instanceof Error ? e.message : String(e);
    options = [];
  }

  if (options.length === 0) {
    // Pozor na rozdíl: „poskytovatel nenašel spoj" a „poskytovatel neběží"
    // vypadají tady stejně, a nesmí. Když poskytovatel odpověděl a nic
    // nenašel, je odpověď prázdná — vymyslet místo toho geometrický odhad by
    // znamenalo tvrdit, že spoj existuje.
    if ((provider === "transitous" || provider === "motis") && providerError === null) {
      const emptyPayload = {
        origin,
        destination: dest,
        direction,
        searched_at: new Date().toISOString(),
        provider,
        has_timetable: true,
        attribution,
        options: [],
        picks: { best: null, cheapest: null, fastest: null, fewest_transfers: null },
        cached: false,
        provider_error: null,
      };
      // Prázdný výsledek se cachuje taky, a krátce. Bez toho by každé otevření
      // obrazovky vyrobilo nový dotaz na komunitní službu kvůli spojení, které
      // stejně neexistuje.
      writeCache(admin, key, provider, origin, dest, windowStart, when, emptyPayload,
        Math.min(ttlMin, 30));
      return json(emptyPayload);
    }
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

  withLocalTimes(options, tz);

  const ranked = rank(options, { groupSize });

  const payload = {
    origin,
    destination: dest,
    direction,
    timezone: tz,
    searched_at: new Date().toISOString(),
    provider: usedProvider,
    // Jasně řečené na úrovni odpovědi, ne jen u ceny: bez jízdního řádu
    // nejsou odhad jen peníze, ale i časy.
    has_timetable: usedProvider === "transitous" || usedProvider === "motis",
    // Transitous vyžaduje viditelný odkaz na zdroje dat. Text jde s odpovědí,
    // takže se nedá zapnout poskytovatel a zapomenout na atribuci.
    attribution,
    provider_error: providerError,
    options: ranked.options.map(serialise),
    picks: {
      best: ranked.best,
      cheapest: ranked.cheapest,
      fastest: ranked.fastest,
      fewest_transfers: ranked.fewestTransfers,
    },
    cached: false,
  };

  writeCache(admin, key, usedProvider, origin, dest, windowStart, when, payload, ttlMin);

  return json(payload);
});

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

/** Zápis do cache nesmí zdržet odpověď ani ji shodit. */
function writeCache(
  admin: Db,
  key: string,
  provider: string,
  origin: Resolved,
  dest: Resolved,
  windowStart: string,
  when: number,
  payload: unknown,
  ttlMin: number,
): void {
  admin
    .from("transport_cache")
    .upsert({
      cache_key: key,
      provider,
      origin_id: origin.id,
      dest_id: dest.id,
      window_start: windowStart,
      window_end: new Date(when + 6 * 3600_000).toISOString(),
      payload,
      expires_at: new Date(Date.now() + ttlMin * 60_000).toISOString(),
      fetched_at: new Date().toISOString(),
    })
    .then(() => {}, (e: unknown) => console.error("cache write failed", e));
}

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
  client: Db,
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

/** Zóna výletu. Čte se přes RLS klienta, takže cizí výlet nic nevrátí. */
async function tripTimezone(
  client: Db,
  tripId: string | undefined,
): Promise<string> {
  if (typeof tripId !== "string" || !UUID.test(tripId)) return DEFAULT_TZ;
  const { data } = await client
    .from("trips")
    .select("timezone")
    .eq("id", tripId)
    .maybeSingle();
  const tz = (data as { timezone?: string } | null)?.timezone;
  return typeof tz === "string" && tz.length > 0 ? tz : DEFAULT_TZ;
}

async function config(
  admin: Db,
): Promise<Record<string, unknown>> {
  const { data } = await admin
    .from("app_config")
    .select("key, value")
    .in("key", [
      "transport_provider",
      "transport_cache_ttl_min",
      "transport_max_walk_m",
      "transitous_url",
      "motis_api_version",
      "transport_user_agent",
      "transport_attribution",
    ]);
  const out: Record<string, unknown> = {};
  for (const r of data ?? []) out[(r as { key: string }).key] = (r as { value: unknown }).value;
  return out;
}

function clamp(n: number, lo: number, hi: number): number {
  return Number.isFinite(n) ? Math.min(Math.max(n, lo), hi) : lo;
}

// ---------------------------------------------------------------------------
// MOTIS / Transitous
// ---------------------------------------------------------------------------

interface MotisQuery {
  origin: Resolved;
  dest: Resolved;
  when: string;
  arriveBy: boolean;
  modes: TransportMode[];
  numItineraries: number;
  maxTransfers: number | null;
}

/** Vyhledání přes MOTIS API.
 *
 *  Jedna implementace pro obě instance. Transitous a vlastní MOTIS mluví
 *  stejným protokolem — liší se jenom základní URL a to, odkud se bere:
 *  komunitní z app_config (je veřejná), vlastní z prostředí funkce (může
 *  nést token). Nikde v kódu není natvrdo napsaný host.
 *
 *  Endpoint je /api/{verze}/plan a verze se mění (aktuálně v6). Konfigurace
 *  drží tu očekávanou; na 404 se zkusí ostatní a nalezená si zapamatuje.
 *  Alternativa — natvrdo v1 — je přesně to, co se jednou tiše rozbije.
 */
async function viaMotisApi(
  provider: string,
  cfg: Record<string, unknown>,
  q: MotisQuery,
): Promise<TransportOption[]> {
  const base = provider === "motis"
    ? Deno.env.get("MOTIS_URL")
    : String(cfg.transitous_url ?? "");
  if (!base) throw new Error(`${provider}: base URL is not configured`);

  const headers: Record<string, string> = { Accept: "application/json" };
  // Transitous to vyžaduje: název aplikace, verze a kontakt. Bez toho je
  // dotaz anonymní zátěž na komunitní službě a oni mají plné právo ho
  // odmítnout.
  //
  // Proto se to kontroluje, ne jen doufá. Podmínka licence, na kterou se dá
  // zapomenout, je podmínka, na kterou se zapomene — a zjistí se to až ve
  // chvíli, kdy nás někdo zablokuje. Chybějící kontakt degraduje na
  // geometrický odhad a důvod jde v `provider_error` na obrazovku.
  const ua = String(cfg.transport_user_agent ?? "");
  if (provider === "transitous" && !/@|https?:\/\//.test(ua)) {
    throw new Error(
      "transitous: transport_user_agent neobsahuje kontakt (e-mail nebo URL). " +
        "Doplň ho v app_config, než na komunitní službu pošleš první dotaz.",
    );
  }
  if (ua) headers["User-Agent"] = ua;
  const token = Deno.env.get("MOTIS_TOKEN");
  if (token && provider === "motis") headers.Authorization = `Bearer ${token}`;

  const configured = String(cfg.motis_api_version ?? "v6");
  const order = [
    discoveredVersion ?? configured,
    ...MOTIS_VERSIONS.filter((v) => v !== (discoveredVersion ?? configured)),
  ];

  let lastStatus = 0;
  for (const version of order) {
    const res = await fetch(planUrl(base, version, q), {
      headers,
      // Timeout je povinný. Bez něj visí Edge Function na cizí nedostupné
      // službě až do vlastního limitu a uživatel kouká na točící se kolečko.
      signal: AbortSignal.timeout(12_000),
    });
    if (res.status === 404) {
      // Tělo se musí přečíst, jinak Deno nechá spojení viset.
      await res.body?.cancel();
      lastStatus = 404;
      continue;
    }
    if (!res.ok) {
      await res.body?.cancel();
      throw new Error(`${provider} ${res.status}`);
    }
    discoveredVersion = version;
    return normaliseMotis(await res.json());
  }
  throw new Error(`${provider}: no /api/*/plan endpoint answered (last ${lastStatus})`);
}

function planUrl(base: string, version: string, q: MotisQuery): URL {
  const u = new URL(`/api/${version}/plan`, base);
  // Souřadnice, ne ID zastávky. ID v naší databázi je naše vlastní UUID
  // z `transit_places` a pro MOTIS nic neznamená — jeho stop ID pocházejí
  // z GTFS feedů, které importujeme jenom kvůli názvům a poloze.
  u.searchParams.set("fromPlace", `${q.origin.lat},${q.origin.lon}`);
  u.searchParams.set("toPlace", `${q.dest.lat},${q.dest.lon}`);
  u.searchParams.set("time", q.when);
  u.searchParams.set("arriveBy", String(q.arriveBy));
  u.searchParams.set("numItineraries", String(q.numItineraries));
  u.searchParams.set("transitModes", motisTransitModes(q.modes).join(","));
  if (q.maxTransfers != null) {
    u.searchParams.set("maxTransfers", String(q.maxTransfers));
  }
  return u;
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
    intermediateStopNames: [],
    scheduledDeparture: null,
    scheduledArrival: null,
    realTime: false,
    cancelled: false,
    localDeparture: null,
    localArrival: null,
  };

  return [
    {
      id: `estimate|public|${Math.round(railKm)}`,
      mode: "train",
      departure: leg.departure,
      arrival: leg.arrival,
      localDeparture: null,
      localArrival: null,
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
    local_departure: o.localDeparture,
    local_arrival: o.localArrival,
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
      local_departure: l.localDeparture,
      local_arrival: l.localArrival,
      scheduled_departure: l.scheduledDeparture,
      scheduled_arrival: l.scheduledArrival,
      real_time: l.realTime,
      duration_minutes: l.durationMinutes,
      distance_meters: l.distanceMeters,
      platform: l.platform,
      trip_id: l.tripId,
      route_id: l.routeId,
      intermediate_stops: l.intermediateStops,
      intermediate_stop_names: l.intermediateStopNames,
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
