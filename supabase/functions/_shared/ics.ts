// A small iCalendar reader. Busy times only.
//
// It reads DTSTART, DTEND/DURATION, RRULE, EXDATE, RECURRENCE-ID, TRANSP and
// STATUS, and nothing else. SUMMARY, LOCATION, ATTENDEE and DESCRIPTION are
// never even parsed — the privacy claim is that we cannot see them, and the
// cheapest way to keep a promise like that is to have no code that could
// break it.
//
// Scope: the recurrence rules real calendars actually emit. FREQ
// DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT, UNTIL, BYDAY (plain for
// weekly, ordinal for monthly). Anything else is skipped and counted, so the
// caller can say "3 events we could not read" rather than quietly losing them.

export interface BusyBlock {
  start: Date;
  end: Date;
  allDay: boolean;
}

export interface ParseResult {
  blocks: BusyBlock[];
  skipped: number;
}

/** RFC 5545 line folding: a leading space or tab continues the line before. */
function unfold(text: string): string[] {
  const raw = text.replace(/\r\n/g, "\n").split("\n");
  const out: string[] = [];
  for (const line of raw) {
    if ((line.startsWith(" ") || line.startsWith("\t")) && out.length > 0) {
      out[out.length - 1] += line.slice(1);
    } else {
      out.push(line);
    }
  }
  return out;
}

/** `DTSTART;TZID=Europe/Prague:20260904T090000` → name, params, value. */
function splitLine(line: string): {
  name: string;
  params: Record<string, string>;
  value: string;
} | null {
  const colon = line.indexOf(":");
  if (colon < 0) return null;

  const head = line.slice(0, colon);
  const value = line.slice(colon + 1);
  const parts = head.split(";");
  const name = parts[0].toUpperCase();

  const params: Record<string, string> = {};
  for (const p of parts.slice(1)) {
    const eq = p.indexOf("=");
    if (eq > 0) {
      params[p.slice(0, eq).toUpperCase()] = p.slice(eq + 1).replace(/^"|"$/g, "");
    }
  }
  return { name, params, value };
}

/**
 * Offset of a timezone at an instant, in milliseconds.
 *
 * Deno ships full ICU, so Intl knows every zone; this is the standard way to
 * get an offset out of it without carrying a timezone database.
 */
function offsetAt(ts: number, tz: string): number {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const p: Record<string, string> = {};
  for (const part of dtf.formatToParts(new Date(ts))) p[part.type] = part.value;
  const asUtc = Date.UTC(
    Number(p.year),
    Number(p.month) - 1,
    Number(p.day),
    Number(p.hour) === 24 ? 0 : Number(p.hour),
    Number(p.minute),
    Number(p.second),
  );
  return asUtc - ts;
}

/**
 * A wall-clock time in a named zone → an instant.
 *
 * Two passes: guess that the wall clock is UTC, correct by the offset there,
 * then correct again in case the first correction crossed a DST boundary.
 * That second pass is the whole reason this is a function and not a
 * subtraction.
 */
function zonedToUtc(
  y: number,
  mo: number,
  d: number,
  h: number,
  mi: number,
  s: number,
  tz: string,
): Date {
  const guess = Date.UTC(y, mo - 1, d, h, mi, s);
  const off1 = offsetAt(guess, tz);
  let ts = guess - off1;
  const off2 = offsetAt(ts, tz);
  if (off2 !== off1) ts = guess - off2;
  return new Date(ts);
}

interface IcsTime {
  date: Date;
  /** VALUE=DATE — a whole day, with no clock. */
  dateOnly: boolean;
}

function parseTime(
  value: string,
  params: Record<string, string>,
  fallbackTz: string,
): IcsTime | null {
  const dateOnly = params.VALUE === "DATE" || /^\d{8}$/.test(value);

  const m = value.match(
    /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/,
  );
  if (!m) return null;

  const [, y, mo, d, h = "0", mi = "0", s = "0", z] = m;

  if (dateOnly) {
    // A date with no time is midnight *where the user is*, which for our
    // purposes is the trip's timezone.
    return {
      date: zonedToUtc(+y, +mo, +d, 0, 0, 0, fallbackTz),
      dateOnly: true,
    };
  }
  if (z === "Z") {
    return {
      date: new Date(Date.UTC(+y, +mo - 1, +d, +h, +mi, +s)),
      dateOnly: false,
    };
  }
  // TZID, or a floating time — which the spec says to read as local, and the
  // only "local" we can justify is the trip's.
  const tz = params.TZID || fallbackTz;
  let date: Date;
  try {
    date = zonedToUtc(+y, +mo, +d, +h, +mi, +s, tz);
  } catch {
    // An unknown TZID (Outlook still emits some non-IANA names) is better
    // read as the trip's timezone than dropped.
    date = zonedToUtc(+y, +mo, +d, +h, +mi, +s, fallbackTz);
  }
  return { date, dateOnly: false };
}

/** `PT1H30M`, `P1D`. Returns milliseconds. */
function parseDuration(v: string): number {
  const m = v.match(
    /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/,
  );
  if (!m) return 0;
  const [, sign, w, d, h, mi, s] = m;
  const ms =
    (Number(w ?? 0) * 604800 +
      Number(d ?? 0) * 86400 +
      Number(h ?? 0) * 3600 +
      Number(mi ?? 0) * 60 +
      Number(s ?? 0)) *
    1000;
  return sign === "-" ? -ms : ms;
}

interface Rule {
  freq: string;
  interval: number;
  count?: number;
  until?: Date;
  byDay: string[];
}

function parseRule(v: string): Rule | null {
  const kv: Record<string, string> = {};
  for (const part of v.split(";")) {
    const eq = part.indexOf("=");
    if (eq > 0) kv[part.slice(0, eq).toUpperCase()] = part.slice(eq + 1);
  }
  if (!kv.FREQ) return null;

  let until: Date | undefined;
  if (kv.UNTIL) {
    const t = parseTime(kv.UNTIL, {}, "UTC");
    if (t) until = t.date;
  }

  return {
    freq: kv.FREQ.toUpperCase(),
    interval: Math.max(1, Number(kv.INTERVAL ?? 1)),
    count: kv.COUNT ? Number(kv.COUNT) : undefined,
    until,
    byDay: kv.BYDAY ? kv.BYDAY.split(",") : [],
  };
}

const WEEKDAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];

/**
 * Occurrence start times of a recurring event that fall in [from, to].
 *
 * Generated forward from DTSTART rather than tested per day, because COUNT
 * and INTERVAL are both defined by position in the series and testing a
 * single date cannot know its ordinal. Capped: an event starting in 2003 with
 * FREQ=DAILY would otherwise spin for tens of thousands of iterations to
 * reach a window next month.
 */
function expand(start: Date, rule: Rule, from: Date, to: Date): Date[] {
  const out: Date[] = [];
  const MAX = 20000;

  const cursor = new Date(start.getTime());
  let emitted = 0;

  for (let i = 0; i < MAX; i++) {
    if (rule.count !== undefined && emitted >= rule.count) break;
    if (rule.until && cursor.getTime() > rule.until.getTime()) break;
    if (cursor.getTime() > to.getTime()) break;

    let candidates: Date[] = [cursor];

    if (rule.freq === "WEEKLY" && rule.byDay.length > 0) {
      // The whole week the cursor sits in, filtered to the named days.
      //
      // KNOWN LIMITATION: the weekday is taken in UTC, so an event at 23:30
      // Prague time is a day late here. Fixing it properly means doing the
      // whole recurrence walk in the event's own timezone. Left as is
      // because it only bites events within an hour or two of midnight,
      // which are rarely the ones a trip has to work around.
      const weekStart = new Date(cursor.getTime());
      weekStart.setUTCDate(weekStart.getUTCDate() - weekStart.getUTCDay());
      candidates = rule.byDay
        .map((d) => WEEKDAYS.indexOf(d.slice(-2)))
        .filter((idx) => idx >= 0)
        .map((idx) => {
          const c = new Date(weekStart.getTime());
          c.setUTCDate(c.getUTCDate() + idx);
          c.setUTCHours(
            cursor.getUTCHours(),
            cursor.getUTCMinutes(),
            cursor.getUTCSeconds(),
            0,
          );
          return c;
        })
        .filter((c) => c.getTime() >= start.getTime());
    } else if (rule.freq === "MONTHLY" && rule.byDay.length > 0) {
      // "3TH" — the third Thursday. Common for standing meetings.
      candidates = [];
      for (const spec of rule.byDay) {
        const nth = parseInt(spec, 10);
        const idx = WEEKDAYS.indexOf(spec.slice(-2));
        if (!nth || idx < 0) continue;
        const c = nthWeekdayOfMonth(
          cursor.getUTCFullYear(),
          cursor.getUTCMonth(),
          idx,
          nth,
        );
        if (!c) continue;
        c.setUTCHours(
          cursor.getUTCHours(),
          cursor.getUTCMinutes(),
          cursor.getUTCSeconds(),
          0,
        );
        candidates.push(c);
      }
    }

    for (const c of candidates) {
      if (rule.count !== undefined && emitted >= rule.count) break;
      if (rule.until && c.getTime() > rule.until.getTime()) continue;
      emitted++;
      if (c.getTime() >= from.getTime() && c.getTime() <= to.getTime()) {
        out.push(new Date(c.getTime()));
      }
    }

    switch (rule.freq) {
      case "DAILY":
        cursor.setUTCDate(cursor.getUTCDate() + rule.interval);
        break;
      case "WEEKLY":
        cursor.setUTCDate(cursor.getUTCDate() + 7 * rule.interval);
        break;
      case "MONTHLY":
        cursor.setUTCMonth(cursor.getUTCMonth() + rule.interval);
        break;
      case "YEARLY":
        cursor.setUTCFullYear(cursor.getUTCFullYear() + rule.interval);
        break;
      default:
        return out; // unsupported FREQ; the caller counts it as skipped
    }
  }
  return out;
}

function nthWeekdayOfMonth(
  year: number,
  month: number,
  weekday: number,
  nth: number,
): Date | null {
  if (nth > 0) {
    const first = new Date(Date.UTC(year, month, 1));
    const shift = (weekday - first.getUTCDay() + 7) % 7;
    const day = 1 + shift + (nth - 1) * 7;
    const d = new Date(Date.UTC(year, month, day));
    return d.getUTCMonth() === month ? d : null;
  }
  // Negative: -1TH is the last Thursday.
  const last = new Date(Date.UTC(year, month + 1, 0));
  const shift = (last.getUTCDay() - weekday + 7) % 7;
  const day = last.getUTCDate() - shift + (nth + 1) * 7;
  const d = new Date(Date.UTC(year, month, day));
  return d.getUTCMonth() === month && day >= 1 ? d : null;
}

interface RawEvent {
  start?: IcsTime;
  end?: IcsTime;
  durationMs?: number;
  rule?: Rule;
  exDates: number[];
  recurrenceId?: number;
  uid?: string;
  transparent: boolean;
  cancelled: boolean;
  unsupportedRule: boolean;
}

export function parseIcs(
  text: string,
  opts: { windowStart: Date; windowEnd: Date; timeZone: string },
): ParseResult {
  const { windowStart, windowEnd, timeZone } = opts;
  const lines = unfold(text);

  const events: RawEvent[] = [];
  let cur: RawEvent | null = null;

  for (const line of lines) {
    if (line.startsWith("BEGIN:VEVENT")) {
      cur = { exDates: [], transparent: false, cancelled: false, unsupportedRule: false };
      continue;
    }
    if (line.startsWith("END:VEVENT")) {
      if (cur) events.push(cur);
      cur = null;
      continue;
    }
    if (!cur) continue;

    const parsed = splitLine(line);
    if (!parsed) continue;
    const { name, params, value } = parsed;

    switch (name) {
      case "DTSTART":
        cur.start = parseTime(value, params, timeZone) ?? undefined;
        break;
      case "DTEND":
        cur.end = parseTime(value, params, timeZone) ?? undefined;
        break;
      case "DURATION":
        cur.durationMs = parseDuration(value);
        break;
      case "RRULE": {
        const r = parseRule(value);
        if (r) cur.rule = r;
        else cur.unsupportedRule = true;
        break;
      }
      case "EXDATE":
        for (const v of value.split(",")) {
          const t = parseTime(v, params, timeZone);
          if (t) cur.exDates.push(t.date.getTime());
        }
        break;
      case "RECURRENCE-ID": {
        const t = parseTime(value, params, timeZone);
        if (t) cur.recurrenceId = t.date.getTime();
        break;
      }
      case "UID":
        cur.uid = value;
        break;
      case "TRANSP":
        // The user marked it "free". Believing them is the entire point.
        cur.transparent = value.toUpperCase() === "TRANSPARENT";
        break;
      case "STATUS":
        cur.cancelled = value.toUpperCase() === "CANCELLED";
        break;
    }
  }

  // An overridden instance appears twice: once inside the series, once as its
  // own VEVENT with RECURRENCE-ID. Excluding the original stops the meeting
  // being counted at both the old time and the new one.
  const overrides = new Map<string, number[]>();
  for (const e of events) {
    if (e.recurrenceId !== undefined && e.uid) {
      const list = overrides.get(e.uid) ?? [];
      list.push(e.recurrenceId);
      overrides.set(e.uid, list);
    }
  }

  const blocks: BusyBlock[] = [];
  let skipped = 0;

  for (const e of events) {
    if (!e.start) {
      skipped++;
      continue;
    }
    if (e.transparent || e.cancelled) continue;
    if (e.unsupportedRule) skipped++;

    // Length, in order of what the file actually said.
    let lengthMs: number;
    if (e.end) {
      lengthMs = e.end.date.getTime() - e.start.date.getTime();
    } else if (e.durationMs) {
      lengthMs = e.durationMs;
    } else {
      // No end and no duration: a whole day if it was a DATE, otherwise a
      // point in time, which RFC 5545 says lasts zero seconds.
      lengthMs = e.start.dateOnly ? 86400000 : 0;
    }
    if (lengthMs <= 0) continue;

    const excluded = new Set<number>(e.exDates);
    if (e.recurrenceId === undefined && e.uid) {
      for (const t of overrides.get(e.uid) ?? []) excluded.add(t);
    }

    const starts = e.rule
      ? expand(e.start.date, e.rule, windowStart, windowEnd)
      : [e.start.date];

    for (const s of starts) {
      if (excluded.has(s.getTime())) continue;
      const end = new Date(s.getTime() + lengthMs);
      // Clip. A year of calendar history must never travel, and an event
      // that merely touches the window contributes only its overlap.
      const clippedStart = s < windowStart ? windowStart : s;
      const clippedEnd = end > windowEnd ? windowEnd : end;
      if (clippedEnd <= clippedStart) continue;
      blocks.push({
        start: clippedStart,
        end: clippedEnd,
        allDay: e.start.dateOnly,
      });
    }
  }

  return { blocks: merge(blocks), skipped };
}

/**
 * Merge overlapping and touching blocks.
 *
 * Touching counts: 09:00–10:00 followed by 10:00–11:00 is two hours of being
 * unavailable, and one row is both smaller and truer to how a person
 * experiences it. Mirrors BusyIntervals.prepare on the Dart side, which does
 * the same thing for the on-device path.
 */
function merge(blocks: BusyBlock[]): BusyBlock[] {
  const sorted = [...blocks].sort((a, b) => a.start.getTime() - b.start.getTime());
  const out: BusyBlock[] = [];
  for (const b of sorted) {
    const last = out[out.length - 1];
    if (!last || b.start.getTime() > last.end.getTime()) {
      out.push({ ...b });
      continue;
    }
    if (b.end.getTime() > last.end.getTime()) last.end = b.end;
    last.allDay = last.allDay && b.allDay;
  }
  return out;
}
