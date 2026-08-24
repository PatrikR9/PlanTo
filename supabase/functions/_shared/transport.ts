// Interní model dopravy + všechno, co se dá spočítat bez sítě.
//
// Nic tady nevolá poskytovatele. Je to schválně: ranking, tarifní odhad i
// klíč do cache jsou čisté funkce, takže se dají otestovat bez MOTISu, bez
// databáze a bez internetu — a jsou to zároveň jediná tři místa, kde se dá
// udělat chyba, kterou uživatel uvidí jako špatné číslo.
//
// Flutter ani M8 nesmí vidět odpověď MOTISu. Tenhle soubor je hranice: co
// projde skrz, je PlanTo model, a výměna poskytovatele je pak práce na
// jedno odpoledne místo refaktoringu.

export type TransportMode =
  | "walk"
  | "train"
  | "metro"
  | "tram"
  | "trolleybus"
  | "bus"
  | "ferry"
  | "funicular"
  | "cablecar"
  | "car"
  | "other";

export type Confidence = "high" | "medium" | "rough";

export interface Place {
  id: string | null;
  name: string;
  lat: number;
  lon: number;
}

export interface TransportLeg {
  mode: TransportMode;
  operatorName: string | null;
  lineName: string | null;
  headsign: string | null;
  fromName: string;
  toName: string;
  fromStopId: string | null;
  toStopId: string | null;
  departure: string; // ISO 8601 s offsetem
  arrival: string;
  durationMinutes: number;
  distanceMeters: number | null;
  platform: string | null;
  tripId: string | null;
  routeId: string | null;
  intermediateStops: number | null;
  /** Jmena mezizastavek. Prazdne pole, kdyz je poskytovatel neposila. */
  intermediateStopNames: string[];
  /** Jizdni rad proti realite. Kdyz se lisi, je spoj zpozdeny. */
  scheduledDeparture: string | null;
  scheduledArrival: string | null;
  realTime: boolean;
  cancelled: boolean;
  /** Nastenne hodiny v zone vyletu, ISO bez offsetu. Klient nema tz databazi
   *  a `toLocal()` na zarizeni v UTC posune cely plan (migrace 20260821140000). */
  localDeparture: string | null;
  localArrival: string | null;
}

export interface FareEstimate {
  min: number;
  max: number;
  currency: string;
  confidence: Confidence;
  /** Vždycky true. Přesnou cenu z veřejné dopravy v ČR zadarmo nevydává
   *  nikdo, takže pole není otázka — je to připomínka pro UI. */
  isEstimate: true;
  /** Co do odhadu vstoupilo. Bez toho se nedá zjistit, proč vyšlo 340 Kč. */
  basis: string[];
}

export interface Ranking {
  score: number;
  reasonCodes: string[];
}

export interface TransportOption {
  id: string;
  mode: TransportMode;
  departure: string;
  arrival: string;
  localDeparture: string | null;
  localArrival: string | null;
  durationMinutes: number;
  transfers: number;
  walkMinutes: number;
  legs: TransportLeg[];
  fare: FareEstimate | null;
  co2Kg: number | null;
  deepLink: string | null;
  ranking: Ranking;
}

export interface FareRule {
  mode: string | null;
  rule_type: "per_km" | "flat" | "zone";
  min_price: number;
  max_price: number;
  currency: string;
  floor_price: number | null;
  cap_price: number | null;
  confidence: Confidence;
  priority: number;
}

// ---------------------------------------------------------------------------
// Klíč do cache
// ---------------------------------------------------------------------------

/** Všechno, co mění výsledek, a nic navíc.
 *
 *  Okno se zaokrouhluje na patnáct minut dolů. Bez zaokrouhlení má každá
 *  sekunda vlastní klíč a cache nikdy netrefí; se zaokrouhlením na hodinu by
 *  odpověď mohla minout spoj, na který se někdo ptal. Patnáct minut je pod
 *  intervalem, ve kterém se jízdní řády opakují.
 */
export function cacheKey(input: {
  provider: string;
  originId: string | null;
  originLat: number;
  originLon: number;
  destId: string | null;
  destLat: number;
  destLon: number;
  windowStart: string;
  arriveBy: boolean;
  direction: string;
  modes: TransportMode[];
}): string {
  const t = Math.floor(Date.parse(input.windowStart) / (15 * 60_000));
  const pt = (id: string | null, lat: number, lon: number) =>
    id ?? `${lat.toFixed(4)},${lon.toFixed(4)}`;
  return [
    "v2",
    input.provider,
    pt(input.originId, input.originLat, input.originLon),
    pt(input.destId, input.destLat, input.destLon),
    t,
    input.arriveBy ? "arr" : "dep",
    // Smer je v klici i pres to, ze ho origin/destination uz odlisuji. Az
    // pribude parametr, ktery se pro zpatecni cestu lisi (jina sada modu,
    // jina tolerance prestupu), byl by bez nej vysledek sdileny mezi smery.
    input.direction,
    [...input.modes].sort().join("+"),
  ].join("|");
}

// ---------------------------------------------------------------------------
// Normalizace MOTISu
// ---------------------------------------------------------------------------

/** MOTIS `Mode` -> nas druh dopravy.
 *
 *  Seznam je opsany z `components/schemas/Mode` v openapi.yaml MOTISu
 *  (motis-project/motis), ne odhadnuty. Dve poznamky, ktere stoji za to:
 *  MOTIS pise `CABLE_CAR` (ne CABLECAR) a zna `METRO` i `SUBWAY` jako dve
 *  hodnoty tehoz. `TROLLEYBUS` v enumu NENI -- trolejbusy chodi jako `BUS`.
 */
const MOTIS_MODES: Record<string, TransportMode> = {
  WALK: "walk",
  BIKE: "walk",
  CAR: "car",
  CAR_PARKING: "car",
  CAR_DROPOFF: "car",
  RENTAL: "other",
  ODM: "other",
  RIDE_SHARING: "car",
  FLEX: "other",
  TRANSIT: "other",
  RAIL: "train",
  HIGHSPEED_RAIL: "train",
  LONG_DISTANCE: "train",
  NIGHT_RAIL: "train",
  REGIONAL_RAIL: "train",
  REGIONAL_FAST_RAIL: "train",
  SUBURBAN: "train",
  MONORAIL: "metro",
  METRO: "metro",
  SUBWAY: "metro",
  TRAM: "tram",
  TROLLEYBUS: "trolleybus",
  BUS: "bus",
  COACH: "bus",
  FERRY: "ferry",
  AIRPLANE: "other",
  FUNICULAR: "funicular",
  CABLE_CAR: "cablecar",
  AERIAL_LIFT: "cablecar",
  AREAL_LIFT: "cablecar",
  OTHER: "other",
};

function motisMode(raw: unknown): TransportMode {
  const key = String(raw ?? "").toUpperCase();
  return MOTIS_MODES[key] ?? "other";
}

/** Hodnoty pro `transitModes` v dotazu na MOTIS.
 *
 *  Posila se jenom to, co enum opravdu zna. Nase `trolleybus` v nem neni a
 *  poslat ho znamena 400 na cely dotaz -- proto padne do `BUS`, kterym
 *  trolejbusy v GTFS stejne jezdi.
 */
export function motisTransitModes(modes: TransportMode[]): string[] {
  const out = new Set<string>();
  for (const m of modes) {
    switch (m) {
      case "train":
        out.add("RAIL");
        break;
      case "metro":
        out.add("SUBWAY");
        break;
      case "tram":
        out.add("TRAM");
        break;
      case "bus":
      case "trolleybus":
        out.add("BUS");
        break;
      case "ferry":
        out.add("FERRY");
        break;
      case "funicular":
        out.add("FUNICULAR");
        break;
      case "cablecar":
        out.add("AERIAL_LIFT");
        break;
      default:
        break;
    }
  }
  // Prazdny seznam nebo plna sada: `TRANSIT` je levnejsi na strane MOTISu a
  // navic pokryje druhy, ktere nase enum nezna (SUBURBAN, COACH, NIGHT_RAIL).
  if (out.size === 0 || out.size >= 5) return ["TRANSIT"];
  return [...out].sort();
}

// ---------------------------------------------------------------------------
// Mistni cas
// ---------------------------------------------------------------------------

/** Okamzik jako nastenne hodiny v dane zone, ISO bez offsetu.
 *
 *  MOTIS vraci casy s offsetem zastavky, takze by sla wall clock vytahnout i
 *  ze samotneho retezce. Geometricky odhad ale zadny offset nema (je to
 *  `toISOString()`, tedy Z), a dve ruzna pravidla pro dva poskytovatele jsou
 *  presne ten druh rozdilu, ktery se projevi az u uzivatele v UTC. Prevadi se
 *  proto oboji stejne, pres zonu vyletu.
 *
 *  `sv-SE` je zkratka na ISO tvar: 2026-09-12 08:25:00.
 */
export function localIso(instant: string, timeZone: string): string | null {
  const ms = Date.parse(instant);
  if (!Number.isFinite(ms)) return null;
  try {
    return new Intl.DateTimeFormat("sv-SE", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hour12: false,
    }).format(new Date(ms)).replace(" ", "T");
  } catch {
    // Neznama zona nesmi shodit odpoved. Klient si poradi i bez mistniho casu
    // -- ukaze cas v zone telefonu, coz je horsi, ne rozbite.
    return null;
  }
}

/** Doplni mistni casy do vsech legu i do hlavicky varianty. */
export function withLocalTimes(
  options: TransportOption[],
  timeZone: string,
): TransportOption[] {
  for (const o of options) {
    o.localDeparture = localIso(o.departure, timeZone);
    o.localArrival = localIso(o.arrival, timeZone);
    for (const l of o.legs) {
      l.localDeparture = localIso(l.departure, timeZone);
      l.localArrival = localIso(l.arrival, timeZone);
    }
  }
  return options;
}

// ---------------------------------------------------------------------------
// Normalizace MOTISu
// ---------------------------------------------------------------------------

/** Odpoved MOTISu (a tim i Transitousu) na PlanTo model.
 *
 *  Nazvy poli jsou z `components/schemas/{Itinerary,Leg,Place}` v openapi.yaml
 *  MOTISu, ne hadane:
 *    Itinerary: duration (SEKUNDY), startTime, endTime, transfers, legs
 *    Leg:       mode, from, to, duration (SEKUNDY), startTime, endTime,
 *               scheduledStartTime, scheduledEndTime, realTime, distance
 *               (METRY), headsign, agencyName, tripId, routeShortName,
 *               routeLongName, displayName, cancelled, intermediateStops
 *    Place:     name, stopId, lat, lon, arrival, departure, scheduledArrival,
 *               scheduledDeparture, track, scheduledTrack
 *
 *  Defenzivni zustava. Verze API se meni (v1..v6) a jedno prejmenovane pole
 *  nesmi shodit obrazovku -- chybejici hodnota je null, ne vyjimka.
 */
export function normaliseMotis(json: unknown): TransportOption[] {
  const root = json as Record<string, unknown>;
  const raw = Array.isArray(root?.itineraries) ? root.itineraries : [];
  const out: TransportOption[] = [];

  for (const itAny of raw) {
    const it = itAny as Record<string, unknown>;
    const rawLegs = Array.isArray(it.legs) ? it.legs : [];
    const legs: TransportLeg[] = [];

    for (const lAny of rawLegs) {
      const l = lAny as Record<string, unknown>;
      const from = (l.from ?? {}) as Record<string, unknown>;
      const to = (l.to ?? {}) as Record<string, unknown>;
      const dep = String(l.startTime ?? from.departure ?? "");
      const arr = String(l.endTime ?? to.arrival ?? "");
      // Leg bez casu neni useku cesty, je to sum. Preskocit ho je lepsi nez
      // ho pustit dal s epochou 1970 -- to by v case ose vypadalo jako plan.
      if (!dep || !arr) continue;

      const stops = Array.isArray(l.intermediateStops)
        ? (l.intermediateStops as Record<string, unknown>[])
        : [];

      legs.push({
        mode: motisMode(l.mode),
        operatorName: str(l.agencyName),
        // routeShortName je "S9", displayName "S9 Praha-Beroun". Kratke jmeno
        // je to, co je na cedulce na peronu.
        lineName: str(l.routeShortName ?? l.displayName ?? l.routeLongName),
        headsign: str(l.headsign),
        fromName: String(from.name ?? ""),
        toName: String(to.name ?? ""),
        fromStopId: str(from.stopId),
        toStopId: str(to.stopId),
        departure: dep,
        arrival: arr,
        // MOTIS posila `duration` v SEKUNDACH. Vzit ho primo a nazvat to
        // minutami je chyba, kterou nikdo nenahlasi -- jenom se plan rozjede.
        durationMinutes: minutesBetween(dep, arr),
        distanceMeters: num(l.distance),
        // `track` je aktualni nastupiste vcetne realtime, `scheduledTrack`
        // to z jizdniho radu. Clovek stoji na tom prvnim.
        platform: str(from.track ?? from.scheduledTrack),
        tripId: str(l.tripId),
        routeId: str(l.routeLongName ?? l.agencyId),
        intermediateStops: stops.length > 0 ? stops.length : null,
        intermediateStopNames: stops
          .map((sp) => String(sp.name ?? ""))
          .filter((n) => n !== ""),
        scheduledDeparture: str(l.scheduledStartTime ?? from.scheduledDeparture),
        scheduledArrival: str(l.scheduledEndTime ?? to.scheduledArrival),
        realTime: l.realTime === true,
        cancelled: l.cancelled === true || from.cancelled === true,
        localDeparture: null,
        localArrival: null,
      });
    }

    if (legs.length === 0) continue;

    const departure = legs[0].departure;
    const arrival = legs[legs.length - 1].arrival;
    const transit = legs.filter((l) => l.mode !== "walk" && l.mode !== "car");

    // Zrusena jizda neni varianta. Vratit ji jako spoj by znamenalo poslat
    // nekoho na nadrazi na vlak, ktery nepojede.
    if (legs.some((l) => l.cancelled)) continue;

    out.push({
      // Deterministicke ID. Nahodne by znamenalo, ze se karta po refreshi
      // povazuje za jinou a seznam pod prstem preskoci.
      id: `${departure}|${arrival}|${transit.map((l) => l.lineName ?? l.mode).join(">")}`,
      mode: transit[0]?.mode ?? "walk",
      departure,
      arrival,
      localDeparture: null,
      localArrival: null,
      durationMinutes: minutesBetween(departure, arrival),
      // Prestup je mezera mezi dvema jizdami, ne pocet legu: pesi usek na
      // zacatku a na konci neni prestup a pocitat ho by nafouklo kazde
      // spojeni o dva. `it.transfers` z MOTISu rika totez, ale spolehnout se
      // na nej znamena verit poli, ktere starsi verze API nemely.
      transfers: Math.max(0, transit.length - 1),
      walkMinutes: legs
        .filter((l) => l.mode === "walk")
        .reduce((a, l) => a + l.durationMinutes, 0),
      legs,
      fare: null,
      co2Kg: null,
      deepLink: null,
      ranking: { score: 0, reasonCodes: [] },
    });
  }
  return out;
}

function str(v: unknown): string | null {
  const s = v == null ? "" : String(v).trim();
  return s === "" ? null : s;
}

function num(v: unknown): number | null {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

export function minutesBetween(a: string, b: string): number {
  const ms = Date.parse(b) - Date.parse(a);
  return Number.isFinite(ms) ? Math.max(0, Math.round(ms / 60_000)) : 0;
}

// ---------------------------------------------------------------------------
// Tarifní odhad
// ---------------------------------------------------------------------------

/** Cena spojení jako rozpětí.
 *
 *  Sčítá se po legách, protože jinou možnost nemáme: integrované tarify
 *  (jedna jízdenka na celou cestu v rámci IDS) by vyšly levněji a náš součet
 *  je proto spíš horní odhad. To je lepší směr chyby než opačný — člověk,
 *  který si vezme víc peněz, se nezasekne na nádraží.
 *
 *  Nejnižší confidence z použitých pravidel vyhrává. Odhad není přesnější
 *  než jeho nejslabší část a tvářit se jinak by bylo to, čemu se celý projekt
 *  vyhýbá.
 */
export function estimateFare(
  legs: TransportLeg[],
  rules: FareRule[],
  currency = "CZK",
): FareEstimate | null {
  const transit = legs.filter((l) => l.mode !== "walk" && l.mode !== "car");
  if (transit.length === 0) return null;

  let min = 0;
  let max = 0;
  let confidence: Confidence = "high";
  const basis: string[] = [];

  for (const leg of transit) {
    const rule = pickRule(rules, leg.mode);
    if (!rule) {
      confidence = "rough";
      basis.push(`${leg.mode}: bez pravidla`);
      continue;
    }
    let lo: number;
    let hi: number;
    if (rule.rule_type === "per_km") {
      // Když vzdálenost neznáme, odhadneme ji z času. Je to hrubé a snižuje
      // to confidence — ale vynechat leg úplně by z ceny udělalo jiné číslo,
      // které jako odhad jenom vypadá.
      const km = leg.distanceMeters != null
        ? leg.distanceMeters / 1000
        : (leg.durationMinutes / 60) * speedKmh(leg.mode);
      if (leg.distanceMeters == null) confidence = weakest(confidence, "rough");
      lo = km * rule.min_price;
      hi = km * rule.max_price;
      if (rule.floor_price != null) {
        lo = Math.max(lo, rule.floor_price);
        hi = Math.max(hi, rule.floor_price);
      }
      if (rule.cap_price != null) {
        lo = Math.min(lo, rule.cap_price);
        hi = Math.min(hi, rule.cap_price);
      }
    } else {
      lo = rule.min_price;
      hi = rule.max_price;
    }
    min += lo;
    max += hi;
    confidence = weakest(confidence, rule.confidence);
    basis.push(`${leg.mode}: ${Math.round(lo)}–${Math.round(hi)} ${currency}`);
  }

  if (max <= 0) return null;

  return {
    // Na desetikoruny. Cena zaokrouhlená na koruny by tvrdila přesnost,
    // kterou model nemá.
    min: Math.floor(min / 10) * 10,
    max: Math.ceil(max / 10) * 10,
    currency,
    confidence,
    isEstimate: true,
    basis,
  };
}

function pickRule(rules: FareRule[], mode: TransportMode): FareRule | null {
  const exact = rules
    .filter((r) => r.mode === mode)
    .sort((a, b) => b.priority - a.priority);
  if (exact.length > 0) return exact[0];
  const fallback = rules
    .filter((r) => r.mode == null)
    .sort((a, b) => b.priority - a.priority);
  return fallback[0] ?? null;
}

function speedKmh(mode: TransportMode): number {
  switch (mode) {
    case "train":
      return 70;
    case "bus":
      return 45;
    case "metro":
      return 33;
    case "tram":
    case "trolleybus":
      return 18;
    default:
      return 40;
  }
}

const ORDER: Confidence[] = ["high", "medium", "rough"];
function weakest(a: Confidence, b: Confidence): Confidence {
  return ORDER.indexOf(a) >= ORDER.indexOf(b) ? a : b;
}

// ---------------------------------------------------------------------------
// CO₂
// ---------------------------------------------------------------------------

// g/os-km, řádové hodnoty pro ČR. Jde o pořadí variant, ne o audit.
const CO2_G_PER_KM: Record<string, number> = {
  train: 25,
  metro: 20,
  tram: 20,
  trolleybus: 25,
  bus: 65,
  ferry: 120,
  car: 160,
  walk: 0,
  funicular: 20,
  cablecar: 20,
  other: 60,
};

export function estimateCo2(legs: TransportLeg[]): number | null {
  let g = 0;
  let known = false;
  for (const l of legs) {
    const km = l.distanceMeters != null
      ? l.distanceMeters / 1000
      : (l.durationMinutes / 60) * speedKmh(l.mode);
    if (l.distanceMeters != null) known = true;
    g += km * (CO2_G_PER_KM[l.mode] ?? 60);
  }
  // Bez jediné známé vzdálenosti je to číslo odvozené z odhadu odhadu.
  // Radši nic než to.
  return known ? Math.round((g / 1000) * 10) / 10 : null;
}

// ---------------------------------------------------------------------------
// Ranking
// ---------------------------------------------------------------------------

export interface RankedResult {
  options: TransportOption[];
  best: string | null;
  cheapest: string | null;
  fastest: string | null;
  fewestTransfers: string | null;
}

/** Deterministické pořadí variant.
 *
 *  Žádná AI. Skóre je vážený součet normalizovaných veličin, takže se dá
 *  otestovat, vysvětlit a zopakovat — a hlavně vrátí stejné pořadí na stejná
 *  data, což je jediný způsob, jak se dá „Doporučeno" brát vážně.
 *
 *  Normalizuje se proti nejlepší variantě v dávce, ne proti absolutním
 *  hodnotám: dvouhodinová cesta je krátká v mezikrajském srovnání a dlouhá
 *  v rámci města, a pevná stupnice by jednu z těch situací hodnotila špatně.
 */
export function rank(
  options: TransportOption[],
  opts: { groupSize?: number } = {},
): RankedResult {
  if (options.length === 0) {
    return { options, best: null, cheapest: null, fastest: null, fewestTransfers: null };
  }

  const price = (o: TransportOption) =>
    o.fare == null ? Number.POSITIVE_INFINITY : (o.fare.min + o.fare.max) / 2;

  const minDur = Math.min(...options.map((o) => o.durationMinutes));
  const finite = options.map(price).filter((p) => Number.isFinite(p));
  const minPrice = finite.length ? Math.min(...finite) : 0;
  const maxPrice = finite.length ? Math.max(...finite) : 0;
  const maxDur = Math.max(...options.map((o) => o.durationMinutes));

  for (const o of options) {
    const durScore = maxDur === minDur
      ? 1
      : 1 - (o.durationMinutes - minDur) / (maxDur - minDur);
    const p = price(o);
    const priceScore = !Number.isFinite(p) || maxPrice === minPrice
      ? 1
      : 1 - (p - minPrice) / (maxPrice - minPrice);
    const transferScore = 1 / (1 + o.transfers);
    // Chůze se počítá zvlášť od času. Dvacet minut v tramvaji a dvacet
    // minut pěšky s batohem nejsou totéž a skupina to cítí jinak.
    const walkScore = Math.max(0, 1 - o.walkMinutes / 40);

    // Ve větší skupině roste váha ceny: pět jízdenek je pětkrát ta částka,
    // zatímco čas každý stráví jednou.
    const group = Math.min(Math.max(opts.groupSize ?? 1, 1), 10);
    const wPrice = 0.20 + Math.min(0.15, (group - 1) * 0.03);
    const wDur = 0.45 - Math.min(0.10, (group - 1) * 0.02);

    o.ranking = {
      score: round2(
        wDur * durScore +
          wPrice * priceScore +
          0.20 * transferScore +
          0.15 * walkScore,
      ),
      reasonCodes: reasons(o, { minDur, minPrice, price: p }),
    };
  }

  // Řazení podle skóre, při shodě podle odjezdu a pak podle ID. Bez druhého
  // a třetího kritéria může sort vrátit dvě různá pořadí pro stejná data.
  const sorted = [...options].sort(
    (a, b) =>
      b.ranking.score - a.ranking.score ||
      Date.parse(a.departure) - Date.parse(b.departure) ||
      (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
  );

  const pickBy = (
    cmp: (a: TransportOption, b: TransportOption) => number,
  ): string | null => {
    const arr = [...sorted].sort(
      (a, b) => cmp(a, b) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
    );
    return arr[0]?.id ?? null;
  };

  return {
    options: sorted,
    best: sorted[0]?.id ?? null,
    fastest: pickBy((a, b) => a.durationMinutes - b.durationMinutes),
    fewestTransfers: pickBy(
      (a, b) => a.transfers - b.transfers || a.durationMinutes - b.durationMinutes,
    ),
    cheapest: finite.length === 0 ? null : pickBy((a, b) => price(a) - price(b)),
  };
}

function reasons(
  o: TransportOption,
  ctx: { minDur: number; minPrice: number; price: number },
): string[] {
  const out: string[] = [];
  if (o.durationMinutes === ctx.minDur) out.push("FASTEST");
  if (Number.isFinite(ctx.price) && ctx.price === ctx.minPrice) {
    out.push("CHEAPEST");
  }
  if (o.transfers === 0) out.push("DIRECT");
  else if (o.transfers === 1) out.push("LOW_TRANSFERS");
  if (o.walkMinutes <= 10) out.push("LITTLE_WALKING");
  if (o.walkMinutes > 30) out.push("LOTS_OF_WALKING");
  if (o.durationMinutes > ctx.minDur * 1.5) out.push("SLOW");
  return out;
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

// ---------------------------------------------------------------------------
// Odkazy ven
// ---------------------------------------------------------------------------

/** Odkaz do IDOS.
 *
 *  Jediný odkaz, který tu je, a schválně. RegioJet ani ČD nemají veřejně
 *  zdokumentovaný stabilní formát pro předvyplněné vyhledání, a odkaz, který
 *  se rozbije při první změně jejich webu, je horší než žádný — člověk na něj
 *  klikne ve chvíli, kdy potřebuje jízdenku.
 */
export function idosLink(from: string, to: string, when?: string): string {
  const u = new URL("https://idos.cz/vlakyautobusymhdvse/spojeni/");
  u.searchParams.set("f", from);
  u.searchParams.set("t", to);
  if (when) {
    const d = new Date(when);
    if (!Number.isNaN(d.getTime())) {
      u.searchParams.set(
        "date",
        `${d.getDate()}.${d.getMonth() + 1}.${d.getFullYear()}`,
      );
      u.searchParams.set(
        "time",
        `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`,
      );
    }
  }
  return u.toString();
}
