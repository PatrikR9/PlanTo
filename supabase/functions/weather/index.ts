// Weather refresh.
//
// Why this exists as a function at all, when Open-Meteo needs no API key and
// the app could call it directly: "the client never talks to a third party"
// is what makes "no API keys in the app" structurally true rather than a
// promise we keep by remembering to. The day a provider does need a key —
// and the self-hosted Open-Meteo on the VPS will, behind basic auth — nothing
// on the client changes.
//
// LICENCE. api.open-meteo.com is free for NON-COMMERCIAL use only. Before
// PlanTo takes a single euro this must point at a self-hosted instance
// (AGPL-3.0 code, open data). That is the ONLY line that has to change:
//
//   const API = Deno.env.get("OPEN_METEO_URL") ?? "https://api.open-meteo.com";
//
// which is why the URL is already an environment variable.
//
// Deploy with: supabase functions deploy weather

import { createClient } from "jsr:@supabase/supabase-js@2";

const API = Deno.env.get("OPEN_METEO_URL") ?? "https://api.open-meteo.com";

// The browser calls this too, now that the web build is the invite fallback.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const DAILY = [
  "weather_code",
  "temperature_2m_max",
  "temperature_2m_min",
  "apparent_temperature_max",
  "precipitation_sum",
  "precipitation_probability_max",
  "wind_gusts_10m_max",
  "snowfall_sum",
  "uv_index_max",
  "sunrise",
  "sunset",
  "daylight_duration",
  "sunshine_duration",
].join(",");

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

/** `2026-08-01` for an instant, as seen in the trip's timezone. */
function localDay(epochSeconds: number, timeZone: string): string {
  // en-CA gives ISO order. Doing this with the timezone rather than a fixed
  // offset is what keeps a window that spans the October clock change correct.
  return new Intl.DateTimeFormat("en-CA", { timeZone }).format(
    new Date(epochSeconds * 1000),
  );
}

function instant(epochSeconds: number | null | undefined): string | null {
  return epochSeconds == null ? null : new Date(epochSeconds * 1000).toISOString();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "missing authorization" }, 401);

  let tripId: string | undefined;
  try {
    tripId = (await req.json())?.trip_id;
  } catch {
    return json({ error: "body must be JSON" }, 400);
  }
  if (!tripId) return json({ error: "trip_id is required" }, 400);

  const url = Deno.env.get("SUPABASE_URL")!;

  // The caller's own token, deliberately. weather_request is membership
  // guarded, so a non-member gets no row and we never learn where their trip
  // is — the authorisation check is the database's, not this function's.
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });

  const { data: rows, error: reqError } = await asUser.rpc("weather_request", {
    p_trip: tripId,
  });
  if (reqError) return json({ error: reqError.message }, 400);

  const plan = rows?.[0];
  if (!plan) return json({ error: "not found" }, 404);

  // The whole point of the cache. If nothing is stale we never touch
  // Open-Meteo, however often the Dates tab is opened.
  if (!plan.stale) return json({ cached: true, days: 0 });

  const params = new URLSearchParams({
    latitude: String(plan.lat),
    longitude: String(plan.lon),
    daily: DAILY,
    timezone: plan.tz,
    timeformat: "unixtime",
    start_date: plan.from_day,
    end_date: plan.to_day,
  });

  const res = await fetch(`${API}/v1/forecast?${params}`);
  const body = await res.json();

  // Open-Meteo answers 400 with {"error":true,"reason":"..."} — a variable
  // name it does not recognise says so precisely. Passing the reason through
  // turns a wrong guess into one readable log line instead of a silent empty
  // forecast.
  if (!res.ok || body?.error) {
    return json({ error: `open-meteo: ${body?.reason ?? res.status}` }, 502);
  }

  const d = body.daily;
  if (!d?.time?.length) return json({ error: "open-meteo returned no days" }, 502);

  const at = <T>(a: T[] | undefined, i: number): T | null => a?.[i] ?? null;

  const rowsToWrite = d.time.map((t: number, i: number) => ({
    lat: plan.lat,
    lon: plan.lon,
    day: localDay(t, plan.tz),
    weather_code: at(d.weather_code, i),
    temp_max: at(d.temperature_2m_max, i),
    temp_min: at(d.temperature_2m_min, i),
    apparent_max: at(d.apparent_temperature_max, i),
    precip_mm: at(d.precipitation_sum, i),
    precip_prob: at(d.precipitation_probability_max, i),
    wind_gust_kmh: at(d.wind_gusts_10m_max, i),
    snowfall_cm: at(d.snowfall_sum, i),
    uv_index: at(d.uv_index_max, i),
    sunrise: instant(at(d.sunrise, i)),
    sunset: instant(at(d.sunset, i)),
    daylight_seconds: Math.round(at(d.daylight_duration, i) ?? 0) || null,
    sunshine_seconds: Math.round(at(d.sunshine_duration, i) ?? 0) || null,
    fetched_at: new Date().toISOString(),
  }));

  // Service role, because weather_daily has no write policy: this function is
  // its single writer and that is enforced rather than agreed.
  const asService = createClient(
    url,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { error: writeError } = await asService
    .from("weather_daily")
    .upsert(rowsToWrite, { onConflict: "lat,lon,day" });

  if (writeError) return json({ error: writeError.message }, 500);

  return json({ cached: false, days: rowsToWrite.length });
});
