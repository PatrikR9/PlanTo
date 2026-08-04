// Calendar by subscription link.
//
// Adds a feed (validating it by fetching it once) and/or re-syncs the saved
// feeds for one trip. Everything it writes is a start/end pair; the parser in
// _shared/ics.ts never even reads a SUMMARY.
//
// Deploy with:
//   supabase secrets set ICAL_SECRET="$(openssl rand -base64 32)"
//   supabase functions deploy ical-sync

import { createClient } from "jsr:@supabase/supabase-js@2";
import { parseIcs } from "../_shared/ics.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** An .ics for a busy year is well under this. A 20 MB one is an attack. */
const MAX_BYTES = 5 * 1024 * 1024;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

/**
 * This function fetches a URL chosen by the user, from inside our
 * infrastructure. That is server-side request forgery unless it is fenced.
 *
 * Blocked: anything but https, IP literals (which is how you reach a cloud
 * metadata endpoint), and hostnames that resolve inside a network by
 * convention. Not a proof — a hostname can still resolve to a private
 * address — but it stops the whole class of copy-paste attacks, and the
 * response never reaches the user as anything except busy times.
 */
function assertSafeUrl(raw: string): URL {
  let u: URL;
  try {
    u = new URL(raw.trim().replace(/^webcal:/i, "https:"));
  } catch {
    throw new Error("To nevypadá jako odkaz.");
  }
  if (u.protocol !== "https:") {
    throw new Error("Odkaz musí začínat https://");
  }
  const host = u.hostname.toLowerCase();
  if (
    /^\d{1,3}(\.\d{1,3}){3}$/.test(host) ||
    host.includes(":") ||
    host === "localhost" ||
    host.endsWith(".localhost") ||
    host.endsWith(".local") ||
    host.endsWith(".internal") ||
    host === "metadata.google.internal"
  ) {
    throw new Error("Tenhle odkaz nejde použít.");
  }
  return u;
}

async function sha256(s: string): Promise<Uint8Array> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return new Uint8Array(buf);
}

function hex(bytes: Uint8Array): string {
  return "\\x" + [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function aesKey(): Promise<CryptoKey> {
  const secret = Deno.env.get("ICAL_SECRET");
  if (!secret) {
    throw new Error(
      "ICAL_SECRET is not set. Run: supabase secrets set " +
        'ICAL_SECRET="$(openssl rand -base64 32)"',
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

async function fetchIcs(url: string): Promise<string> {
  const res = await fetch(url, {
    redirect: "follow",
    headers: { Accept: "text/calendar, text/plain" },
    signal: AbortSignal.timeout(20000),
  });
  if (!res.ok) {
    // The provider's own status, because "404" and "403" call for different
    // reactions from the person who pasted the link.
    throw new Error(`Kalendář odpověděl ${res.status}.`);
  }
  const size = Number(res.headers.get("content-length") ?? 0);
  if (size > MAX_BYTES) throw new Error("Kalendář je moc velký.");

  const text = await res.text();
  if (text.length > MAX_BYTES) throw new Error("Kalendář je moc velký.");
  if (!text.includes("BEGIN:VCALENDAR")) {
    throw new Error("Na téhle adrese není kalendář ve formátu iCal.");
  }
  return text;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "missing authorization" }, 401);

  let body: { trip_id?: string; url?: string; label?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "body must be JSON" }, 400);
  }
  const tripId = body.trip_id;
  if (!tripId) return json({ error: "trip_id is required" }, 400);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;

  // The caller's own token. ical_sync_request is membership guarded, so a
  // non-member gets no row and this function never has to decide who may read
  // a trip.
  const asUser = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });

  const { data: me } = await asUser.auth.getUser();
  const userId = me?.user?.id;
  if (!userId) return json({ error: "not authenticated" }, 401);

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

  // ---- adding a new feed -------------------------------------------------
  if (body.url) {
    let url: URL;
    try {
      url = assertSafeUrl(body.url);
    } catch (e) {
      return json({ error: (e as Error).message }, 400);
    }

    // Fetch before saving. A link that does not work is worse than no link:
    // the group would wait on availability that is never coming.
    let text: string;
    try {
      text = await fetchIcs(url.toString());
    } catch (e) {
      return json({ error: (e as Error).message }, 400);
    }

    const { error: saveError } = await asService.from("calendar_feeds").upsert(
      {
        user_id: userId,
        label: (body.label ?? url.hostname).slice(0, 60),
        host: url.hostname,
        url_cipher: await encrypt(url.toString()),
        url_hash: hex(await sha256(url.toString())),
        last_synced_at: new Date().toISOString(),
        last_error: null,
      },
      { onConflict: "user_id,url_hash" },
    );
    if (saveError) return json({ error: saveError.message }, 500);
  }

  // ---- syncing every saved feed for this trip -----------------------------
  const { data: feeds, error: feedError } = await asService
    .from("calendar_feeds")
    .select("id, url_cipher")
    .eq("user_id", userId);
  if (feedError) return json({ error: feedError.message }, 500);
  if (!feeds?.length) return json({ error: "Nemáte uložený žádný odkaz." }, 400);

  const rows: { start: Date; end: Date; allDay: boolean }[] = [];
  let skipped = 0;
  const failures: string[] = [];

  for (const feed of feeds) {
    try {
      const text = await fetchIcs(await decrypt(feed.url_cipher));
      const parsed = parseIcs(text, {
        windowStart,
        windowEnd,
        timeZone: plan.tz,
      });
      rows.push(...parsed.blocks);
      skipped += parsed.skipped;
      await asService
        .from("calendar_feeds")
        .update({ last_synced_at: new Date().toISOString(), last_error: null })
        .eq("id", feed.id);
    } catch (e) {
      // One dead feed must not lose the others. The error is kept against the
      // feed so the UI can say which one, rather than failing the whole sync.
      const message = (e as Error).message;
      failures.push(message);
      await asService
        .from("calendar_feeds")
        .update({ last_error: message })
        .eq("id", feed.id);
    }
  }

  if (rows.length === 0 && failures.length === feeds.length) {
    return json({ error: failures[0] }, 400);
  }

  // Replace, never append — the same rule the manual editor and the Android
  // sync follow. Sources are mutually exclusive per (trip, user) because
  // "the calendar says free, the person says busy" has no correct merge.
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
        is_all_day: b.allDay,
        source_kind: "ical",
      })),
    );
    if (insertError) return json({ error: insertError.message }, 500);
  }

  // An empty calendar is a real answer — "nothing blocks me" — and the most
  // useful one there is. It must count as having shared, or the group waits
  // forever on somebody who already replied.
  await asService
    .from("trip_participants")
    .update({ calendar_shared: true })
    .eq("trip_id", tripId)
    .eq("user_id", userId);

  return json({ blocks: rows.length, skipped, failures });
});
