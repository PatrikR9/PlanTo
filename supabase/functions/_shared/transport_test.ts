// deno test supabase/functions/_shared/
//
// Testuje se to, co se dá otestovat bez sítě: ranking, tarifní odhad, klíč do
// cache a normalizace odpovědi. Jsou to zároveň jediná místa, kde se dá
// udělat chyba, kterou uživatel uvidí jako špatné číslo — samotné volání
// MOTISu je jen HTTP.

import {
  assert,
  assertAlmostEquals,
  assertEquals,
  assertNotEquals,
} from "jsr:@std/assert@1";
import {
  cacheKey,
  estimateFare,
  type FareRule,
  idosLink,
  normaliseMotis,
  rank,
  type TransportLeg,
  type TransportOption,
} from "./transport.ts";

// ---------------------------------------------------------------------------
// Pomůcky
// ---------------------------------------------------------------------------

function leg(p: Partial<TransportLeg> = {}): TransportLeg {
  return {
    mode: "train",
    operatorName: "ČD",
    lineName: "R 670",
    headsign: null,
    fromName: "Praha hl.n.",
    toName: "Brno hl.n.",
    fromStopId: null,
    toStopId: null,
    departure: "2026-09-12T07:14:00+02:00",
    arrival: "2026-09-12T09:44:00+02:00",
    durationMinutes: 150,
    distanceMeters: 255_000,
    platform: "3",
    tripId: null,
    routeId: null,
    intermediateStops: 4,
    ...p,
  };
}

function option(p: Partial<TransportOption> = {}): TransportOption {
  const legs = p.legs ?? [leg()];
  return {
    id: p.id ?? "o1",
    mode: "train",
    departure: legs[0].departure,
    arrival: legs[legs.length - 1].arrival,
    durationMinutes: 150,
    transfers: 0,
    walkMinutes: 0,
    legs,
    fare: null,
    co2Kg: null,
    deepLink: null,
    ranking: { score: 0, reasonCodes: [] },
    ...p,
  };
}

const RULES: FareRule[] = [
  {
    mode: "train",
    rule_type: "per_km",
    min_price: 1.6,
    max_price: 2.6,
    currency: "CZK",
    floor_price: 30,
    cap_price: 700,
    confidence: "medium",
    priority: 10,
  },
  {
    mode: "tram",
    rule_type: "flat",
    min_price: 20,
    max_price: 40,
    currency: "CZK",
    floor_price: null,
    cap_price: null,
    confidence: "medium",
    priority: 20,
  },
  {
    mode: null,
    rule_type: "per_km",
    min_price: 1.2,
    max_price: 2.6,
    currency: "CZK",
    floor_price: 25,
    cap_price: 700,
    confidence: "rough",
    priority: 0,
  },
];

// ---------------------------------------------------------------------------
// Tarif
// ---------------------------------------------------------------------------

Deno.test("známé pravidlo dá rozpětí, ne jedno číslo", () => {
  const f = estimateFare([leg()], RULES)!;
  assert(f.min < f.max, "odhad bez rozpětí předstírá přesnost");
  assertEquals(f.currency, "CZK");
  assertEquals(f.isEstimate, true);
  assertEquals(f.confidence, "medium");
  // 255 km × 1,60 = 408, × 2,60 = 663, obojí pod stropem 700.
  assertEquals(f.min, 400);
  assertEquals(f.max, 670);
});

Deno.test("neznámý druh dopravy spadne na obecné pravidlo a sníží confidence", () => {
  const f = estimateFare([leg({ mode: "ferry", distanceMeters: 3000 })], RULES)!;
  assertEquals(f.confidence, "rough");
  assert(f.max > 0);
});

Deno.test("nejslabší článek určuje confidence celého odhadu", () => {
  // Vlak (medium) + přívoz na obecné pravidlo (rough) = rough. Odhad není
  // přesnější než jeho nejhorší část.
  const f = estimateFare(
    [leg(), leg({ mode: "ferry", distanceMeters: 2000 })],
    RULES,
  )!;
  assertEquals(f.confidence, "rough");
});

Deno.test("chybějící vzdálenost se dopočítá z času, ale přizná se", () => {
  const f = estimateFare([leg({ distanceMeters: null })], RULES)!;
  assertEquals(f.confidence, "rough");
  assert(f.max > f.min);
});

Deno.test("minimální jízdné se uplatní na krátkou jízdu", () => {
  const f = estimateFare(
    [leg({ distanceMeters: 4000, durationMinutes: 8 })],
    RULES,
  )!;
  // 4 km × 1,60 = 6,40 Kč, což by za jízdenku nekoupil nikdo. Floor je 30.
  assert(f.min >= 30, `min ${f.min} ignoruje floor_price`);
});

Deno.test("chůze se neúčtuje", () => {
  assertEquals(estimateFare([leg({ mode: "walk" })], RULES), null);
});

// ---------------------------------------------------------------------------
// Ranking
// ---------------------------------------------------------------------------

Deno.test("ranking je deterministický", () => {
  const build = () => [
    option({ id: "a", durationMinutes: 124, transfers: 1 }),
    option({ id: "b", durationMinutes: 158, transfers: 2 }),
    option({ id: "c", durationMinutes: 124, transfers: 1 }),
  ];
  const first = rank(build()).options.map((o) => o.id);
  const second = rank(build()).options.map((o) => o.id);
  assertEquals(first, second, "stejná data musí dát stejné pořadí");
});

Deno.test("nejrychlejší, nejlevnější a nejmíň přestupů jsou tři různé otázky", () => {
  const fast = option({
    id: "fast",
    durationMinutes: 100,
    transfers: 3,
    fare: {
      min: 500, max: 600, currency: "CZK", confidence: "medium",
      isEstimate: true, basis: [],
    },
  });
  const cheap = option({
    id: "cheap",
    durationMinutes: 180,
    transfers: 2,
    fare: {
      min: 200, max: 260, currency: "CZK", confidence: "medium",
      isEstimate: true, basis: [],
    },
  });
  const direct = option({
    id: "direct",
    durationMinutes: 150,
    transfers: 0,
    fare: {
      min: 340, max: 420, currency: "CZK", confidence: "medium",
      isEstimate: true, basis: [],
    },
  });
  const r = rank([fast, cheap, direct]);
  assertEquals(r.fastest, "fast");
  assertEquals(r.cheapest, "cheap");
  assertEquals(r.fewestTransfers, "direct");
  assert(r.best !== null);
});

Deno.test("ve větší skupině roste váha ceny", () => {
  const mk = () => [
    option({
      id: "fast",
      durationMinutes: 100,
      fare: {
        min: 900, max: 1000, currency: "CZK", confidence: "medium",
        isEstimate: true, basis: [],
      },
    }),
    option({
      id: "cheap",
      durationMinutes: 140,
      fare: {
        min: 200, max: 240, currency: "CZK", confidence: "medium",
        isEstimate: true, basis: [],
      },
    }),
  ];
  const solo = rank(mk(), { groupSize: 1 });
  const group = rank(mk(), { groupSize: 6 });
  const gap = (r: ReturnType<typeof rank>) =>
    r.options.find((o) => o.id === "cheap")!.ranking.score -
    r.options.find((o) => o.id === "fast")!.ranking.score;
  assert(gap(group) > gap(solo), "šest jízdenek musí vážit víc než jedna");
});

Deno.test("prázdný vstup nevrací výběr", () => {
  const r = rank([]);
  assertEquals(r.best, null);
  assertEquals(r.cheapest, null);
});

Deno.test("bez ceny se nejlevnější neurčuje", () => {
  const r = rank([option({ id: "a" }), option({ id: "b", durationMinutes: 200 })]);
  assertEquals(r.cheapest, null, "cena, kterou neznáme, nesmí vyrobit vítěze");
});

Deno.test("důvody jsou kódy, ne věty", () => {
  const r = rank([option({ id: "a", transfers: 0, walkMinutes: 5 })]);
  const codes = r.options[0].ranking.reasonCodes;
  assert(codes.includes("DIRECT"));
  assert(codes.includes("LITTLE_WALKING"));
  for (const c of codes) {
    assertEquals(c, c.toUpperCase(), "kód se překládá na klientovi");
  }
});

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

const BASE = {
  provider: "motis",
  originId: "11111111-1111-1111-1111-111111111111",
  originLat: 50.083,
  originLon: 14.435,
  destId: "22222222-2222-2222-2222-222222222222",
  destLat: 49.191,
  destLon: 16.612,
  windowStart: "2026-09-12T07:00:00Z",
  arriveBy: false,
  modes: ["train", "bus"] as const,
};

Deno.test("stejný dotaz dá stejný klíč", () => {
  assertEquals(
    cacheKey({ ...BASE, modes: [...BASE.modes] }),
    cacheKey({ ...BASE, modes: [...BASE.modes].reverse() }),
    "pořadí druhů dopravy není součást dotazu",
  );
});

Deno.test("jiné časové okno je jiný klíč", () => {
  assertNotEquals(
    cacheKey({ ...BASE, modes: [...BASE.modes] }),
    cacheKey({
      ...BASE,
      modes: [...BASE.modes],
      windowStart: "2026-09-12T19:00:00Z",
    }),
    "bez času v klíči vrátí cache ranní vlak na dotaz na večerní",
  );
});

Deno.test("okno se zaokrouhluje na čtvrthodinu, ne na sekundu", () => {
  assertEquals(
    cacheKey({ ...BASE, modes: [...BASE.modes] }),
    cacheKey({
      ...BASE,
      modes: [...BASE.modes],
      windowStart: "2026-09-12T07:11:30Z",
    }),
  );
  assertNotEquals(
    cacheKey({ ...BASE, modes: [...BASE.modes] }),
    cacheKey({
      ...BASE,
      modes: [...BASE.modes],
      windowStart: "2026-09-12T07:16:00Z",
    }),
  );
});

Deno.test("příjezd a odjezd nejsou zaměnitelné", () => {
  assertNotEquals(
    cacheKey({ ...BASE, modes: [...BASE.modes] }),
    cacheKey({ ...BASE, modes: [...BASE.modes], arriveBy: true }),
  );
});

// ---------------------------------------------------------------------------
// Normalizace
// ---------------------------------------------------------------------------

Deno.test("pěší úseky na krajích nejsou přestupy", () => {
  const opts = normaliseMotis({
    itineraries: [
      {
        legs: [
          {
            mode: "WALK",
            startTime: "2026-09-12T07:00:00+02:00",
            endTime: "2026-09-12T07:08:00+02:00",
            from: { name: "Doma" },
            to: { name: "Praha hl.n." },
          },
          {
            mode: "RAIL",
            startTime: "2026-09-12T07:14:00+02:00",
            endTime: "2026-09-12T09:44:00+02:00",
            from: { name: "Praha hl.n.", track: "3" },
            to: { name: "Brno hl.n." },
            routeShortName: "R 670",
            agencyName: "ČD",
          },
          {
            mode: "WALK",
            startTime: "2026-09-12T09:44:00+02:00",
            endTime: "2026-09-12T09:52:00+02:00",
            from: { name: "Brno hl.n." },
            to: { name: "Hotel" },
          },
        ],
      },
    ],
  });
  assertEquals(opts.length, 1);
  assertEquals(opts[0].transfers, 0, "chůze na začátku a konci není přestup");
  assertEquals(opts[0].walkMinutes, 16);
  assertEquals(opts[0].legs[1].platform, "3");
  assertEquals(opts[0].legs[1].operatorName, "ČD");
  assertAlmostEquals(opts[0].durationMinutes, 52, 1);
});

Deno.test("dvě jízdy znamenají jeden přestup", () => {
  const opts = normaliseMotis({
    itineraries: [
      {
        legs: [
          {
            mode: "RAIL",
            startTime: "2026-09-12T07:00:00Z",
            endTime: "2026-09-12T08:00:00Z",
            from: {}, to: {},
          },
          {
            mode: "BUS",
            startTime: "2026-09-12T08:10:00Z",
            endTime: "2026-09-12T08:40:00Z",
            from: {}, to: {},
          },
        ],
      },
    ],
  });
  assertEquals(opts[0].transfers, 1);
});

Deno.test("prázdná nebo poškozená odpověď nevyhodí výjimku", () => {
  assertEquals(normaliseMotis({}).length, 0);
  assertEquals(normaliseMotis({ itineraries: null }).length, 0);
  assertEquals(normaliseMotis({ itineraries: [{ legs: [{}] }] }).length, 0);
  assertEquals(normaliseMotis("nesmysl").length, 0);
});

Deno.test("ID varianty je odvozené, ne náhodné", () => {
  const payload = {
    itineraries: [
      {
        legs: [
          {
            mode: "RAIL",
            startTime: "2026-09-12T07:00:00Z",
            endTime: "2026-09-12T08:00:00Z",
            from: {}, to: {}, routeShortName: "R 670",
          },
        ],
      },
    ],
  };
  assertEquals(normaliseMotis(payload)[0].id, normaliseMotis(payload)[0].id);
});

// ---------------------------------------------------------------------------
// Odkazy
// ---------------------------------------------------------------------------

Deno.test("odkaz do IDOS nese obě zastávky i datum", () => {
  const u = new URL(idosLink("Praha hl.n.", "Brno hl.n.", "2026-09-12T07:14:00Z"));
  assertEquals(u.hostname, "idos.cz");
  assertEquals(u.searchParams.get("f"), "Praha hl.n.");
  assertEquals(u.searchParams.get("t"), "Brno hl.n.");
  assert(u.searchParams.get("date")?.includes("2026"));
});
