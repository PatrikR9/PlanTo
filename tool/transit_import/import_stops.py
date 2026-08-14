#!/usr/bin/env python3
"""Naplní transit_stops z veřejných GTFS feedů.

    python tool/transit_import/import_stops.py --db "$DB_URL"
    python tool/transit_import/import_stops.py --db "$DB_URL" --feed pid
    python tool/transit_import/import_stops.py --csv-only --out _tmp/stops

Pipeline:

    stáhni → rozparsuj → normalizuj → deduplikuj → zvaliduj → staging
                                                                 ↓
                                          import_transit_stops(feed)
                                                                 ↓
                                             rebuild_transit_places()

Je to idempotentní. Dvakrát puštěné nad stejnými daty dá stejnou databázi;
zastávka, která z feedu zmizela, se označí (retired_at), nesmaže — výlet,
který na ni ukazuje, by jinak přišel o souřadnice.

Běží proti service_role, ne proti anon klíči: staging tabulka i obě importní
funkce jsou schválně odebrané roli authenticated.

Závislosti: psycopg[binary] pro zápis do databáze. Bez --db (režim --csv-only)
stačí čisté Python 3.9+.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import sys
import time
import zipfile
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterator
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent

# csv modul má výchozí limit pole 128 kB a některé GTFS feedy ho v poznámkách
# překročí. Padá to až v půlce souboru, takže to vypadá jako poškozený zip.
csv.field_size_limit(min(sys.maxsize, 2**31 - 1))

# ---------------------------------------------------------------------------
# Číselníky
# ---------------------------------------------------------------------------

# GTFS route_type → stop_mode enum v databázi. Wire hodnoty jsou kontrakt,
# ne popisky: přejmenovat je znamená tichou ztrátu dat (past 12 v registru).
#
# Rozšířené typy (Google/HVT, stovky) jsou tu proto, že je české feedy
# používají — CZPTT posílá vlaky jako 100+ a ne jako 2, a bez tohohle by
# každý vlak spadl do 'other'.
BASIC_ROUTE_TYPES = {
    0: "tram",
    1: "metro",
    2: "train",
    3: "bus",
    4: "ferry",
    5: "cablecar",
    6: "cablecar",
    7: "funicular",
    11: "trolleybus",
    12: "other",
}

EXTENDED_RANGES = [
    (100, 199, "train"),
    (200, 299, "bus"),        # dálkové autobusy
    (400, 499, "train"),      # městská železnice, S-linky
    (500, 599, "metro"),
    (600, 699, "metro"),
    (700, 799, "bus"),
    (800, 899, "trolleybus"),
    (900, 999, "tram"),
    (1000, 1099, "ferry"),
    (1100, 1199, "other"),    # letecká doprava
    (1200, 1299, "ferry"),
    (1300, 1399, "cablecar"),
    (1400, 1499, "funicular"),
    (1500, 1599, "bus"),
    (1700, 1799, "other"),
]


def route_type_to_mode(raw: str) -> str:
    try:
        rt = int(raw)
    except (TypeError, ValueError):
        return "other"
    if rt in BASIC_ROUTE_TYPES:
        return BASIC_ROUTE_TYPES[rt]
    for lo, hi, mode in EXTENDED_RANGES:
        if lo <= rt <= hi:
            return mode
    return "other"


# Stát se bere z konfigurace feedu, ne ze souřadnic.
#
# První verze ho hádala z obdélníkových obálek států. Görlitz vyšel jako
# polský a Bratislava padla do rakouské i slovenské obálky zároveň —
# obdélník prostě není hranice. Přesně by to uměl jen další dataset s
# vlastní licencí, a to za údaj, který se v aplikaci nikde nezobrazuje.
#
# Pohraniční stanice v CZPTT tedy zůstávají vedené jako české. Je to známá
# nepřesnost popsaná tady, ne tvrzení, kterému někdo uvěří.


# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

STAGING_COLUMNS = [
    "feed_id",
    "source_stop_id",
    "name",
    "lat",
    "lon",
    "mode",
    "location_type",
    "source_parent_id",
    "city",
    "district",
    "region",
    "country",
    "wheelchair",
    "platform_code",
    "zone_id",
    "timezone",
    "departures_per_day",
]


@dataclass
class Stop:
    feed_id: str
    source_stop_id: str
    name: str
    lat: float
    lon: float
    mode: str = "other"
    location_type: int = 0
    source_parent_id: str | None = None
    city: str | None = None
    district: str | None = None
    region: str | None = None
    country: str = "CZ"
    wheelchair: int | None = None
    platform_code: str | None = None
    zone_id: str | None = None
    timezone: str = "Europe/Prague"
    departures_per_day: int = 0

    def row(self) -> list[Any]:
        return [getattr(self, c) for c in STAGING_COLUMNS]


@dataclass
class FeedResult:
    feed_id: str
    stops: list[Stop] = field(default_factory=list)
    dropped: dict[str, int] = field(default_factory=lambda: defaultdict(int))


# ---------------------------------------------------------------------------
# Stahování
# ---------------------------------------------------------------------------


def download(url: str, dest: Path, skip: bool, attempts: int = 3) -> Path:
    """Stáhne soubor a při přerušeném spojení to zkusí znovu.

    `RemoteDisconnected: Remote end closed connection without response` je u
    velkých souborů přes CDN běžné a většinou přechodné — server spojení
    zahodí bez odpovědi, další pokus o pár vteřin později projde. Padat na
    první pokus u čtyřicetimegabajtového zipu znamená, že se import nedotáhne
    kvůli něčemu, co samo přejde.
    """
    if skip and dest.exists() and dest.stat().st_size > 0:
        print(f"  cache  {dest.name} ({dest.stat().st_size / 1e6:.1f} MB)")
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"  stahuji {url}")
    # Prohlížečová hlavička: GitHub a některé CDN zahazují spojení od klientů,
    # které nepoznají, a to bez jakékoli odpovědi — takže se to neprojeví jako
    # 403, ale právě jako RemoteDisconnected.
    req = Request(url, headers={
        "User-Agent": (
            "Mozilla/5.0 (compatible; PlanTo transit import; "
            "+https://github.com/PatrikR9/PlanTo)"
        ),
        "Accept": "*/*",
    })
    tmp = dest.with_suffix(dest.suffix + ".part")

    for attempt in range(1, attempts + 1):
        try:
            with urlopen(req, timeout=300) as resp, tmp.open("wb") as out:
                while chunk := resp.read(1 << 20):
                    out.write(chunk)
            break
        except Exception as exc:  # noqa: BLE001 — na síti selže cokoli
            tmp.unlink(missing_ok=True)
            if attempt == attempts:
                raise
            wait = 2 ** attempt
            print(f"  pokus {attempt}/{attempts} selhal ({exc}) — "
                  f"zkouším za {wait} s")
            time.sleep(wait)
    # Přejmenování až na konci: přerušené stahování nesmí příště projít jako
    # platná cache. Půlka zipu se pozná až při parsování a vypadá to jako
    # rozbitý feed na straně dopravce.
    tmp.replace(dest)
    print(f"  hotovo {dest.name} ({dest.stat().st_size / 1e6:.1f} MB)")
    return dest


# ---------------------------------------------------------------------------
# GTFS
# ---------------------------------------------------------------------------


class Gtfs:
    """Streamovaný přístup do GTFS zipu.

    stop_times.txt má u celostátního feedu přes šest milionů řádků a čtvrt
    gigabajtu. Nikdy se nenačítá celý — jenom se přes něj jednou přejde.
    """

    def __init__(self, path: Path):
        self.zip = zipfile.ZipFile(path)
        # Některé feedy mají soubory ve složce uvnitř archivu.
        self.index = {
            Path(n).name.lower(): n
            for n in self.zip.namelist()
            if not n.endswith("/")
        }

    def has(self, name: str) -> bool:
        return name in self.index or name + ".gz" in self.index

    def rows(self, name: str) -> Iterator[dict[str, str]]:
        member = self.index.get(name)
        if member is None:
            member = self.index.get(name + ".gz")
            if member is None:
                return
            import gzip

            raw = gzip.open(self.zip.open(member), "rt",
                            encoding="utf-8-sig", errors="replace")
        else:
            raw = io.TextIOWrapper(
                self.zip.open(member), encoding="utf-8-sig", errors="replace"
            )
        with raw as fh:
            yield from csv.DictReader(fh)

    def close(self) -> None:
        self.zip.close()


def service_days_per_week(g: Gtfs) -> dict[str, int]:
    """Kolik dnů v týdnu daná služba jede.

    Je to váha pro pořadí ve vyhledávání, ne jízdní řád. Zastávka, na které
    staví školní spoj dvakrát týdně, nemá vyhrát nad hlavním nádražím jen
    proto, že se ve feedu vyskytuje stejněkrát.
    """
    days: dict[str, int] = {}
    if g.has("calendar.txt"):
        for r in g.rows("calendar.txt"):
            sid = r.get("service_id")
            if not sid:
                continue
            days[sid] = sum(
                1
                for d in ("monday", "tuesday", "wednesday", "thursday",
                          "friday", "saturday", "sunday")
                if r.get(d) == "1"
            )
    if g.has("calendar_dates.txt"):
        extra: dict[str, int] = defaultdict(int)
        for r in g.rows("calendar_dates.txt"):
            if r.get("exception_type") == "1":
                extra[r.get("service_id", "")] += 1
        for sid, n in extra.items():
            # Služba, která existuje jen v calendar_dates. Feed může pokrývat
            # rok, takže počet výjimek není počet dnů v týdnu — jde jenom o to
            # odlišit „jede skoro pořád" od „jede třikrát za rok", a na to
            # strop na sedmi stačí.
            if sid and sid not in days:
                days[sid] = max(1, min(7, n))
    return days


def parse_gtfs(path: Path, feed_id: str, default_country: str) -> FeedResult:
    g = Gtfs(path)
    res = FeedResult(feed_id)
    try:
        if not g.has("stops.txt"):
            raise SystemExit(f"{feed_id}: v archivu není stops.txt")

        route_mode = {
            r["route_id"]: route_type_to_mode(r.get("route_type", ""))
            for r in g.rows("routes.txt")
            if r.get("route_id")
        }
        weekly = service_days_per_week(g)

        # trip_id → (mode, dny v týdnu). Ukládá se jen tohle, ne celý řádek:
        # u celostátního feedu je to 400 tisíc záznamů a zbytek by byl balast.
        trip_info: dict[str, tuple[str, int]] = {}
        for r in g.rows("trips.txt"):
            tid = r.get("trip_id")
            if not tid:
                continue
            trip_info[tid] = (
                route_mode.get(r.get("route_id", ""), "other"),
                weekly.get(r.get("service_id", ""), 5),
            )

        # Jeden průchod stop_times: kolik odjezdů a čeho na zastávce staví.
        per_stop_mode: dict[str, dict[str, int]] = defaultdict(
            lambda: defaultdict(int)
        )
        if g.has("stop_times.txt"):
            for r in g.rows("stop_times.txt"):
                info = trip_info.get(r.get("trip_id", ""))
                if info is None:
                    continue
                sid = r.get("stop_id")
                if not sid:
                    continue
                mode, dpw = info
                per_stop_mode[sid][mode] += dpw

        for r in g.rows("stops.txt"):
            sid = (r.get("stop_id") or "").strip()
            name = (r.get("stop_name") or "").strip()
            if not sid or not name:
                res.dropped["bez id nebo jména"] += 1
                continue
            try:
                lat = float(r["stop_lat"])
                lon = float(r["stop_lon"])
            except (KeyError, TypeError, ValueError):
                res.dropped["bez souřadnic"] += 1
                continue
            # 0,0 je Guinejský záliv. V datech to znamená „chybí"; pustit to
            # dál by vyrobilo zastávku stejně daleko od všeho.
            if abs(lat) < 0.01 and abs(lon) < 0.01:
                res.dropped["souřadnice 0,0"] += 1
                continue
            if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                res.dropped["souřadnice mimo rozsah"] += 1
                continue

            loc_type = _int(r.get("location_type"), 0) or 0
            modes = per_stop_mode.get(sid)
            if modes:
                # Převažující druh dopravy, při shodě abecedně — determinismus,
                # ne náhoda podle pořadí v souboru.
                mode = sorted(modes.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
                departures = sum(modes.values()) // 7
            else:
                mode = "other"
                departures = 0

            # Stanice (location_type=1) nemá vlastní stop_times; dědí druh
            # dopravy po svých nástupištích, jinak by každé nádraží skončilo
            # jako 'other' a v hledání by propadlo.
            res.stops.append(
                Stop(
                    feed_id=feed_id,
                    source_stop_id=sid,
                    name=name,
                    lat=lat,
                    lon=lon,
                    mode=mode,
                    location_type=loc_type,
                    source_parent_id=(r.get("parent_station") or "").strip() or None,
                    zone_id=(r.get("zone_id") or "").strip() or None,
                    platform_code=(r.get("platform_code") or "").strip() or None,
                    wheelchair=_int(r.get("wheelchair_boarding"), None),
                    timezone=(r.get("stop_timezone") or "").strip() or "Europe/Prague",
                    country=default_country,
                    departures_per_day=departures,
                )
            )

        _inherit_parent_modes(res.stops)
    finally:
        g.close()
    return res


def _inherit_parent_modes(stops: list[Stop]) -> None:
    by_id = {s.source_stop_id: s for s in stops}
    children: dict[str, list[Stop]] = defaultdict(list)
    for s in stops:
        if s.source_parent_id:
            children[s.source_parent_id].append(s)
    for pid, kids in children.items():
        parent = by_id.get(pid)
        if parent is None:
            continue
        if parent.mode == "other":
            tally: dict[str, int] = defaultdict(int)
            for k in kids:
                tally[k.mode] += max(1, k.departures_per_day)
            if tally:
                parent.mode = sorted(tally.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
        if parent.departures_per_day == 0:
            parent.departures_per_day = sum(k.departures_per_day for k in kids)


def _int(v: Any, default: int | None) -> int | None:
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------------------
# PID: obec a okres
# ---------------------------------------------------------------------------


def enrich_from_pid(res: FeedResult, url: str, cache: Path, skip: bool) -> None:
    """Doplní obec a okres z PID stop listu.

    GTFS stops.txt nemá kam obec zapsat, takže bez tohohle je „Chrášťany"
    čtyřikrát to samé slovo. PID jako jediný ten údaj publikuje a váže ho na
    asw_node_id, které je i v jeho GTFS.
    """
    path = download(url, cache, skip)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"  ! PID stop list se nepovedlo přečíst ({exc}); "
              f"obec a okres zůstanou prázdné")
        return

    # node → (obec, okres). Skupina nese oboje, sloupek jenom svoje id.
    #
    # Klíče se hledají víc způsoby schválně. XML schéma je zdokumentované,
    # JSON export ne, a jediné, co je na něm jisté, je že se obsahově shoduje
    # s XML. Když se přejmenuje obal, je to varování a prázdný okres — ne
    # spadlý import.
    groups = None
    for key in ("stopGroups", "groups", "stop_groups"):
        if isinstance(data.get(key), list):
            groups = data[key]
            break
    if groups is None and isinstance(data, list):
        groups = data
    if not groups:
        print("  ! PID stop list nemá seznam skupin — struktura se změnila, "
              "obec a okres zůstanou prázdné")
        return

    by_node: dict[str, tuple[str | None, str | None]] = {}
    for group in groups:
        if not isinstance(group, dict):
            continue
        node = str(group.get("node") or "").strip()
        if not node:
            continue
        by_node[node] = (
            (group.get("municipality") or None),
            (group.get("districtCode") or group.get("district") or None),
        )

    if not by_node:
        print("  ! PID stop list nemá uzly — struktura se změnila")
        return

    hit = 0
    for s in res.stops:
        node = _pid_node(s.source_stop_id)
        if node and node in by_node:
            s.city, s.district = by_node[node]
            hit += 1
    print(f"  obec/okres doplněny u {hit} z {len(res.stops)} zastávek")


def _pid_node(stop_id: str) -> str | None:
    """U1072Z101P → 1072.

    PID skládá stop_id jako U<uzel>[SZ]<sloupek>[P]. Uzel je to, co váže
    zastávku na skupinu v stop listu.
    """
    if not stop_id.startswith("U"):
        return None
    digits = ""
    for ch in stop_id[1:]:
        if ch.isdigit():
            digits += ch
        else:
            break
    return digits or None


# ---------------------------------------------------------------------------
# Deduplikace a validace
# ---------------------------------------------------------------------------


def dedupe(res: FeedResult) -> None:
    """Jedno source_stop_id, jeden řádek.

    Feedy to porušují — PID přidává druhý záznam, když se zastávka během
    platnosti feedu přejmenuje nebo změní zónu. Vyhrává víc odjezdů, pak
    delší jméno; deterministicky, protože jinak dva běhy importu dají dvě
    různé databáze a nikdo si toho nevšimne.
    """
    best: dict[str, Stop] = {}
    for s in res.stops:
        cur = best.get(s.source_stop_id)
        if cur is None or (s.departures_per_day, len(s.name)) > (
            cur.departures_per_day,
            len(cur.name),
        ):
            best[s.source_stop_id] = s
    res.dropped["duplicitní id"] += len(res.stops) - len(best)
    res.stops = sorted(best.values(), key=lambda s: s.source_stop_id)


def validate(res: FeedResult) -> None:
    if not res.stops:
        raise SystemExit(f"{res.feed_id}: import by smazal celý feed — nic k nahrání")
    # Sanity check proti tichému rozpadu zdroje. Feed, který se scvrkl na
    # zlomek, je pravděpodobně chyba na jejich straně, ne skutečnost, a
    # označit tisíce zastávek jako zrušené se špatně vrací zpátky.
    named = sum(1 for s in res.stops if len(s.name) > 1)
    if named < len(res.stops) * 0.9:
        raise SystemExit(f"{res.feed_id}: víc než desetina zastávek nemá jméno")
    orphans = 0
    ids = {s.source_stop_id for s in res.stops}
    for s in res.stops:
        if s.source_parent_id and s.source_parent_id not in ids:
            s.source_parent_id = None
            orphans += 1
    if orphans:
        print(f"  {orphans}× parent_station ukazuje mimo feed — zahozeno")


# ---------------------------------------------------------------------------
# Zápis
# ---------------------------------------------------------------------------


def write_csv(res: FeedResult, out: Path) -> Path:
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"{res.feed_id}.csv"
    with path.open("w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(STAGING_COLUMNS)
        for s in res.stops:
            w.writerow(["" if v is None else v for v in s.row()])
    print(f"  zapsáno {path} ({len(res.stops)} zastávek)")
    return path


def load_into_db(conn, res: FeedResult) -> None:
    cols = ", ".join(STAGING_COLUMNS)
    with conn.cursor() as cur:
        # Staging se čistí per feed, ne celý: běh jednoho feedu nesmí zahodit
        # rozpracovaný jiný.
        cur.execute("delete from transit_stops_staging where feed_id = %s",
                    (res.feed_id,))
        with cur.copy(
            f"copy transit_stops_staging ({cols}) from stdin"
        ) as copy:
            for s in res.stops:
                copy.write_row(s.row())
        cur.execute("select * from import_transit_stops(%s)", (res.feed_id,))
        ins, upd, ret, _rev = cur.fetchone()
        print(f"  {res.feed_id}: +{ins} nových, {upd} aktualizovaných, "
              f"{ret} označeno jako zrušené")
    conn.commit()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default=os.environ.get("DB_URL"),
                    help="Postgres URL (service_role). Bez něj jen CSV.")
    ap.add_argument("--feed", action="append",
                    help="jen tenhle feed, lze opakovat")
    ap.add_argument("--csv-only", action="store_true")
    ap.add_argument("--out", default="_tmp/stops", type=Path)
    ap.add_argument("--cache", default="_tmp/feeds", type=Path)
    ap.add_argument("--skip-download", action="store_true",
                    help="použij, co je v cache")
    ap.add_argument("--no-rebuild", action="store_true",
                    help="nepřepočítávat transit_places (jen při ladění)")
    args = ap.parse_args()

    cfg = json.loads((HERE / "feeds.json").read_text(encoding="utf-8"))
    feeds = cfg["feeds"]
    if args.feed:
        wanted = set(args.feed)
        feeds = [f for f in feeds if f["id"] in wanted]
        missing = wanted - {f["id"] for f in feeds}
        if missing:
            raise SystemExit(f"neznámý feed: {', '.join(sorted(missing))}")

    conn = None
    if not args.csv_only:
        if not args.db:
            raise SystemExit(
                "chybí --db (nebo DB_URL). Bez databáze pusť --csv-only."
            )
        try:
            import psycopg
        except ImportError:
            raise SystemExit(
                "psycopg není nainstalované:  pip install 'psycopg[binary]'"
            )

        # Nezapomenutý zástupný text pozná psycopg taky, ale řekne to jako
        # 'missing "=" after "<URI" in connection info string', což je
        # pravdivé a k ničemu. Tady je vidět, co se stalo.
        if not args.db.startswith(("postgres://", "postgresql://")):
            raise SystemExit(
                "--db nevypadá jako connection string:\n"
                f"  {args.db!r}\n\n"
                "Čeká se URI ve tvaru "
                "postgresql://postgres.<ref>:<heslo>@<host>:5432/postgres\n"
                "Najdeš ho v Supabase → Connect → Connection string → URI.\n"
                "Pozor: obsahuje [YOUR-PASSWORD], které se musí nahradit "
                "skutečným heslem k databázi."
            )
        if "[YOUR-PASSWORD]" in args.db or "<" in args.db:
            raise SystemExit(
                "V connection stringu zůstal zástupný text — nahraď ho "
                "heslem k databázi (Supabase → Settings → Database)."
            )

        conn = psycopg.connect(args.db)

    # Jeden nedostupný feed nesmí shodit ostatní.
    #
    # Zdroje jsou tři cizí servery a jeden z nich je navíc mirror v cizím
    # GitHub repozitáři. Že bude občas nedostupný, není výjimečný stav, ale
    # normální provoz. Předchozí verze na tom padala tracebackem — a to i ve
    # chvíli, kdy už měla PID i vlaky úspěšně zpracované, tedy dost dat na to,
    # aby vyhledávání fungovalo. Částečný import je použitelný; žádný není.
    results: list[FeedResult] = []
    failed: list[tuple[str, str]] = []
    for f in feeds:
        print(f"\n== {f['id']} ==")
        try:
            archive = download(f["url"], args.cache / f"{f['id']}.zip",
                               args.skip_download)
            res = parse_gtfs(archive, f["id"], f.get("country", "CZ"))
            if f.get("enrich_pid_stops"):
                enrich_from_pid(res, f["enrich_pid_stops"],
                                args.cache / f"{f['id']}_stops.json",
                                args.skip_download)
            dedupe(res)
            validate(res)
        except Exception as exc:  # noqa: BLE001
            print(f"  PŘESKOČENO — {type(exc).__name__}: {exc}")
            failed.append((f["id"], f"{type(exc).__name__}: {exc}"))
            continue

        for reason, n in sorted(res.dropped.items()):
            if n:
                print(f"  zahozeno {n}× — {reason}")
        print(f"  {len(res.stops)} zastávek k nahrání")
        if args.csv_only:
            write_csv(res, args.out)
        else:
            load_into_db(conn, res)
        results.append(res)

    if not results:
        print("\nNepodařilo se zpracovat ani jeden feed.")
        for fid, why in failed:
            print(f"  {fid}: {why}")
        return 1

    if conn is not None and not args.no_rebuild:
        print("\n== přepočet míst ==")
        with conn.cursor() as cur:
            cur.execute("select rebuild_transit_places()")
            print(f"  {cur.fetchone()[0]} vyhledatelných míst")
        conn.commit()
        conn.close()

    total = sum(len(r.stops) for r in results)
    print(f"\nhotovo: {total} zastávek z {len(results)} feedů")

    # Nenulový návratový kód i při částečném úspěchu: databáze je použitelná,
    # ale neúplná, a to se v CI ani v terminálu nesmí ztratit mezi řádky.
    if failed:
        print("\nNedokončené feedy:")
        for fid, why in failed:
            print(f"  {fid}: {why}")
        print("Data z nich chybí. Spusť import znovu, až budou dostupné —"
              " je idempotentní.")
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
