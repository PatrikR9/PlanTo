// deno test supabase/functions/_shared/ics_test.ts
//
// The parser is one of the four things worth near-total coverage: a bug here
// silently reports somebody as free when they are not, and the group finds
// out on the platform.

import { assertEquals } from "jsr:@std/assert@1";
import { parseIcs } from "./ics.ts";

const WINDOW = {
  windowStart: new Date("2026-09-01T00:00:00+02:00"),
  windowEnd: new Date("2026-09-30T00:00:00+02:00"),
  timeZone: "Europe/Prague",
};

function ics(body: string): string {
  return `BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${body}\r\nEND:VCALENDAR`;
}

Deno.test("a plain event becomes one busy block", () => {
  const r = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:1\r\nDTSTART;TZID=Europe/Prague:20260904T090000\r\n" +
        "DTEND;TZID=Europe/Prague:20260904T103000\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(r.blocks.length, 1);
  assertEquals(r.blocks[0].start.toISOString(), "2026-09-04T07:00:00.000Z");
  assertEquals(r.blocks[0].end.toISOString(), "2026-09-04T08:30:00.000Z");
});

Deno.test("a UTC event is not shifted twice", () => {
  const r = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:2\r\nDTSTART:20260904T090000Z\r\n" +
        "DTEND:20260904T100000Z\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(r.blocks[0].start.toISOString(), "2026-09-04T09:00:00.000Z");
});

Deno.test("an all-day event covers the whole local day", () => {
  const r = parseIcs(
    ics("BEGIN:VEVENT\r\nUID:3\r\nDTSTART;VALUE=DATE:20260904\r\nEND:VEVENT"),
    WINDOW,
  );
  assertEquals(r.blocks[0].allDay, true);
  // Midnight to midnight in Prague, which in September is UTC+2.
  assertEquals(r.blocks[0].start.toISOString(), "2026-09-03T22:00:00.000Z");
  assertEquals(r.blocks[0].end.toISOString(), "2026-09-04T22:00:00.000Z");
});

Deno.test("TRANSPARENT and CANCELLED events are not busy", () => {
  // The user marked it free. Believing them is the entire point — an
  // all-day "holiday" feed would otherwise block every day of the trip.
  const transparent = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:4\r\nDTSTART:20260904T090000Z\r\n" +
        "DTEND:20260904T100000Z\r\nTRANSP:TRANSPARENT\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(transparent.blocks.length, 0);

  const cancelled = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:5\r\nDTSTART:20260904T090000Z\r\n" +
        "DTEND:20260904T100000Z\r\nSTATUS:CANCELLED\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(cancelled.blocks.length, 0);
});

Deno.test("a weekly rule expands inside the window only", () => {
  // Every Friday from January. Only the Fridays in September may appear —
  // a year of calendar history must never travel.
  const r = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:6\r\nDTSTART;TZID=Europe/Prague:20260102T090000\r\n" +
        "DTEND;TZID=Europe/Prague:20260102T100000\r\n" +
        "RRULE:FREQ=WEEKLY;BYDAY=FR\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  // 4, 11, 18, 25 September 2026 are Fridays.
  assertEquals(r.blocks.length, 4);
  assertEquals(r.blocks[0].start.toISOString(), "2026-09-04T07:00:00.000Z");
});

Deno.test("UNTIL stops the series", () => {
  const r = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:7\r\nDTSTART;TZID=Europe/Prague:20260902T090000\r\n" +
        "DTEND;TZID=Europe/Prague:20260902T100000\r\n" +
        "RRULE:FREQ=DAILY;UNTIL=20260904T235959Z\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(r.blocks.length, 3);
});

Deno.test("EXDATE removes one occurrence", () => {
  const r = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:8\r\nDTSTART;TZID=Europe/Prague:20260902T090000\r\n" +
        "DTEND;TZID=Europe/Prague:20260902T100000\r\n" +
        "RRULE:FREQ=DAILY;COUNT=3\r\n" +
        "EXDATE;TZID=Europe/Prague:20260903T090000\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(r.blocks.length, 2);
});

Deno.test("a moved instance is not counted at both times", () => {
  // The override carries RECURRENCE-ID; without excluding the original the
  // person is busy twice for one meeting.
  const r = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:9\r\nDTSTART;TZID=Europe/Prague:20260902T090000\r\n" +
        "DTEND;TZID=Europe/Prague:20260902T100000\r\n" +
        "RRULE:FREQ=DAILY;COUNT=2\r\nEND:VEVENT\r\n" +
        "BEGIN:VEVENT\r\nUID:9\r\n" +
        "RECURRENCE-ID;TZID=Europe/Prague:20260903T090000\r\n" +
        "DTSTART;TZID=Europe/Prague:20260903T140000\r\n" +
        "DTEND;TZID=Europe/Prague:20260903T150000\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(r.blocks.length, 2);
  // The second block is the moved one, at 14:00 local.
  assertEquals(r.blocks[1].start.toISOString(), "2026-09-03T12:00:00.000Z");
});

Deno.test("overlapping and touching blocks are merged", () => {
  const r = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:10\r\nDTSTART:20260904T090000Z\r\n" +
        "DTEND:20260904T100000Z\r\nEND:VEVENT\r\n" +
        "BEGIN:VEVENT\r\nUID:11\r\nDTSTART:20260904T100000Z\r\n" +
        "DTEND:20260904T110000Z\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(r.blocks.length, 1);
  assertEquals(r.blocks[0].end.toISOString(), "2026-09-04T11:00:00.000Z");
});

Deno.test("an event straddling the window edge is clipped", () => {
  const r = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:12\r\nDTSTART:20260831T200000Z\r\n" +
        "DTEND:20260901T060000Z\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(r.blocks.length, 1);
  assertEquals(
    r.blocks[0].start.toISOString(),
    WINDOW.windowStart.toISOString(),
  );
});

Deno.test("folded lines are rejoined", () => {
  // RFC 5545 wraps at 75 octets and continues with a leading space. A parser
  // that misses this silently truncates a TZID.
  const r = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:13\r\nDTSTART;TZID=Europe/Pra\r\n gue:20260904T090000\r\n" +
        "DTEND;TZID=Europe/Prague:20260904T100000\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(r.blocks[0].start.toISOString(), "2026-09-04T07:00:00.000Z");
});

Deno.test("DURATION is used when there is no DTEND", () => {
  const r = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:14\r\nDTSTART:20260904T090000Z\r\n" +
        "DURATION:PT1H30M\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(r.blocks[0].end.toISOString(), "2026-09-04T10:30:00.000Z");
});

Deno.test("an event outside the window contributes nothing", () => {
  const r = parseIcs(
    ics(
      "BEGIN:VEVENT\r\nUID:15\r\nDTSTART:20260704T090000Z\r\n" +
        "DTEND:20260704T100000Z\r\nEND:VEVENT",
    ),
    WINDOW,
  );
  assertEquals(r.blocks.length, 0);
});
