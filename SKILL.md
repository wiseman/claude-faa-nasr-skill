---
name: faa-nasr
description: Query local FAA NASR (National Airspace System Resources) databases — airports, runways, navaids, fixes, airways, ILS, ATC frequencies, obstacles, controlled airspace (Class B/C/D/E), and special-use airspace (Restricted, Prohibited, MOA, Warning, Alert). Triggers on questions about specific airports/runways/navaids/fixes, ATC or AWOS frequencies, airspace geometry/floors/ceilings, obstacle locations, military training routes, parachute jump areas, ARTCC boundaries, or anything that needs the FAA 28-day NASR cycle data. Also covers refreshing the local databases from the latest FAA subscription, and (optionally) joining NASR data spatially against an external ADS-B parquet archive.
---

# FAA NASR data

Local SQLite/SpatiaLite databases built from the FAA's 28-day NASR
subscription, plus GeoParquet sidecars of the spatial layers for fast
DuckDB joins. This skill covers what is where, how to query each store,
the schema gotchas, and how to refresh.

The build tool is `$PROCESS_FAA_DATA_DIR` — see `scripts/setup.sh` for
how to install it. If the user hasn't built the data yet, run
`./scripts/setup.sh --all`; if they have but the install looks broken,
run `./scripts/doctor.sh`.

## Configuration — paths

The skill resolves all paths via environment variables, with the
defaults below. Source `scripts/load-config.sh` before running shell
commands to populate them; or run `scripts/doctor.sh --paths` to see
what they currently resolve to.

| Variable | Default | What |
|---|---|---|
| `NASR_DATA_DIR` | `~/data/faa/nasr` | Built sqlite + parquet + `CYCLE.txt` |
| `PROCESS_FAA_DATA_DIR` | `~/src/processFaaData` | Clone of the build tool |
| `ADSB_PARQUET_DIR` | (unset) | Optional: ADS-B parquet archive for cross-format joins |
| `SQLITE_BIN` | auto-detected | sqlite3 binary that supports `.load mod_spatialite` |
| `MOD_SPATIALITE_PATH` | auto-detected | Full path to the SpatiaLite shared library |

Override via env vars or by editing `config.sh` (template:
`config.sh.example`). The user's `README.md` documents the discovery
order.

## Where the data lives

All under `$NASR_DATA_DIR`:

| File | Contents | When to use |
| --- | --- | --- |
| `nasr.sqlite` | Plain SQLite, ~70 NASR tables (APT, NAV, FIX, AWY, ILS, TWR, COM, FSS, AWOS, OBSTACLE, MTR, ARB, …). No geometry. | Attribute lookups, joins between subject tables. |
| `spatialite_nasr.sqlite` | Same tables, SpatiaLite-wrapped with `GEOMETRY` columns and R-tree indexes on the locatable layers. | Geographic queries (`ST_Within`, nearest, bbox). |
| `controlled_airspace_spatialite.sqlite` | Single layer `Class_Airspace` (B/C/D/E shelves as `MULTIPOLYGON`). | Class B/C/D/E geometry & altitudes. |
| `special_use_airspace_spatialite.sqlite` | AIXM-style: `Airspace`, `AirspaceUsage`, `AirTrafficControlService`, … | Restricted, Prohibited, MOA, Warning, Alert, ATCAA. |
| `class_airspace.parquet` | GeoParquet sidecar of `Class_Airspace`. | DuckDB joins (no SpatiaLite-blob friction). |
| `special_use_airspace.parquet` | GeoParquet sidecar of SUA `Airspace`. | DuckDB joins. |
| `obstacle.parquet` | GeoParquet sidecar of `OBSTACLE_OBSTACLE` (~530k rows). | Bulk obstacle queries / wide aggregations. |
| `CYCLE.txt` | Marker file recording the cycle date (e.g. `2026-04-16`). | Read first to know how stale the data is. |
| `28DaySubscription_Effective_<DATE>.zip` + unpacked dir | Source of last build; kept for auditability. | Don't query directly. |

If `CYCLE.txt` is missing, the cycle is the date in the
`NASR_28DaySubscription_Effective_*` directory name. If both are
missing, run a refresh.

## Cycle freshness — check this first

Before answering anything substantive, read `CYCLE.txt` (or the
unpacked-zip directory name). If the cycle is more than ~28 days old,
**mention it and offer to refresh**:

> "Your NASR build is from cycle YYYY-MM-DD (N days old, M cycles
> behind). Want me to refresh before answering?"

For passing-interest questions (general airport facts, runway counts)
staleness rarely matters. For airspace, ILS, frequency, or obstacle
questions where the answer might have changed, push harder. **Never
auto-refresh without asking** — a full rebuild is ~5 min and ~250 MB
downloaded.

To check whether a newer cycle exists:

```bash
cd "$PROCESS_FAA_DATA_DIR" && ./get_current_nasr_url.py
```

Returns the URL of the current cycle's zip; the date is in the
filename. To actually refresh, run `./scripts/refresh.sh`. Procedure
and troubleshooting in `references/refresh.md`.

## Decision tree — which store for which question

| Question shape | Use |
| --- | --- |
| Airport / runway / navaid / fix / airway / ILS / tower / comms attributes only | `nasr.sqlite` |
| "Near point X", "within Y miles", "closest to" | `spatialite_nasr.sqlite` + `mod_spatialite` |
| Class B/C/D/E geometry & altitudes (interactive) | `controlled_airspace_spatialite.sqlite` |
| SUA polygons & altitudes (interactive) | `special_use_airspace_spatialite.sqlite` |
| NASR polygon × any external parquet (e.g. ADS-B) | DuckDB on the GeoParquet sidecar + the external parquet |
| Bulk obstacle queries, wide aggregations over OBSTACLE | DuckDB on `obstacle.parquet` |

Recipes for each row are in `references/cookbook.md`. Schema reference
for the underlying tables is in `references/schema.md`.

## Querying SpatiaLite

Use `$SQLITE_BIN` and `$MOD_SPATIALITE_PATH` (auto-detected by
`scripts/load-config.sh` / `scripts/doctor.sh`). On Linux/WSL the
bare name `mod_spatialite` resolves via the loader's standard search
path; on macOS the dylib's full path must be used because the dyld
search path for sqlite child processes does NOT include
`/opt/homebrew/lib` (or `/usr/local/lib`).

**macOS gotcha:** Apple's `/usr/bin/sqlite3` is built with
`SQLITE_OMIT_LOAD_EXTENSION`, so `.load mod_spatialite` fails silently.
The auto-detection prefers Homebrew's
`/opt/homebrew/opt/sqlite/bin/sqlite3` (Apple Silicon) or
`/usr/local/opt/sqlite/bin/sqlite3` (Intel). `brew install sqlite` if
missing. Alternatives:

- **Python**: `con.enable_load_extension(True);
  con.load_extension(os.environ['MOD_SPATIALITE_PATH'])`.
- **DuckDB** (different SQL dialect, but reads `.sqlite` via the
  `sqlite_scanner` extension and can do spatial via its own `spatial`
  extension on the GeoParquet sidecars).

```bash
"$SQLITE_BIN" "$NASR_DATA_DIR/spatialite_nasr.sqlite"
sqlite> .load $MOD_SPATIALITE_PATH
sqlite> SELECT location_identifier
        FROM APT_APT
        WHERE PtDistWithin(referenceGeom, MakePoint(-118.4, 33.94, 4326), 50000)
        LIMIT 10;
```

R-tree indexes follow `idx_<TABLE>_<GEOMCOL>` and are used
automatically when filtering with functions that recognize them
(`ST_Intersects`, `ST_Within`, `MbrIntersects`, `PtDistWithin`). For
nearest-neighbor at scale, use the `KNN` virtual table.

CRS is **WGS84 / EPSG:4326** throughout. `MakePoint` arguments are
**lon, lat, srid** in that order.

## Querying with DuckDB (cross-format and bulk)

```bash
duckdb
D INSTALL spatial; LOAD spatial;
D SELECT NAME, ST_AsText(GEOMETRY)
  FROM read_parquet(getenv('NASR_DATA_DIR') || '/class_airspace.parquet')
  WHERE CLASS='B' LIMIT 5;
```

DuckDB's `getenv()` reads the env var at query time, so as long as
your shell has `NASR_DATA_DIR` set (via `source scripts/load-config.sh`)
the path resolves automatically. If you'd rather hardcode a path,
substitute `$NASR_DATA_DIR/class_airspace.parquet`.

DuckDB cannot directly read SpatiaLite-blob geometry from the `.sqlite`
files — that's a custom format, not standard WKB. The parquet sidecars
exist to bridge that gap. If you need an ad-hoc polygon out of
SpatiaLite into DuckDB, export with `AsWKT(GEOMETRY)` from sqlite3 and
`ST_GeomFromText` it on the DuckDB side.

## (Optional) Joining NASR × ADS-B parquet

If you have an ADS-B archive (e.g. ADS-B Exchange / airplanes.live raw
JSON converted to parquet), you can use the GeoParquet sidecars to
spatially join NASR airspace polygons against aircraft track points.

**Skip this section unless `$ADSB_PARQUET_DIR` is set.** The skill
deliberately leaves it unset by default; users who don't have an
archive should ignore the rest of this section.

Common ADS-B parquet schemas vary by tool. Two seen in the wild:

| Schema | Source | Key columns | Squawk type |
| --- | --- | --- | --- |
| airplanes.live raw | direct dump of /aircraft.json | `hex`, `flight`, `r`, `t`, `lat`, `lon`, `alt_baro`, `now`, `squawk` | VARCHAR (`'1200'`) |
| adsbx2parquet output | jjwiseman/gnss-interference Rust tool | `icao24`, `callsign`, `registration`, `aircraft_type`, `latitude`, `longitude`, `baro_altitude`, `timestamp`, `squawk` | INTEGER (`1200`) |

Pattern for any "aircraft inside / near a NASR polygon" query:

```sql
-- DuckDB
INSTALL spatial; LOAD spatial;
WITH region AS (
  SELECT GEOMETRY AS geom, LOWER_VAL AS lower_ft, UPPER_VAL AS upper_ft, NAME
  FROM read_parquet(getenv('NASR_DATA_DIR') || '/class_airspace.parquet')
  WHERE <your filter>
),
bb AS (
  SELECT MIN(ST_XMin(geom)) AS mnlon, MIN(ST_YMin(geom)) AS mnlat,
         MAX(ST_XMax(geom)) AS mxlon, MAX(ST_YMax(geom)) AS mxlat
  FROM region
)
SELECT t.icao24, t.timestamp, t.latitude, t.longitude, t.baro_altitude, t.squawk
FROM read_parquet(getenv('ADSB_PARQUET_DIR') || '/<files>') t, region r, bb
WHERE t.latitude  BETWEEN bb.mnlat AND bb.mxlat       -- bbox prefilter, critical
  AND t.longitude BETWEEN bb.mnlon AND bb.mxlon
  AND t.baro_altitude BETWEEN r.lower_ft AND r.upper_ft
  AND ST_Within(ST_Point(t.longitude, t.latitude), r.geom);
```

Always add the bbox prefilter before `ST_Within` — ADS-B parquet
typically has no spatial index, so without it DuckDB scans every row
group in the archive.

**Temporal alignment.** NASR is a 28-day cycle. When querying historical
ADS-B (>28 days old), the *current* NASR cycle may not match the
airspace that was in effect at the time. Note this in answers when the
gap matters (airspace boundary changes, ILS frequency reassignments,
runway closures). For interactive-era queries this is usually moot.

## Schema gotchas

- **Subject prefix → multiple subtables.** `APT_APT` is the airport
  master record; `APT_RWY` is runways; `APT_RMK` is remarks.
  `TWR_TWR1..TWR9` are different tower-record types — `TWR_TWR3` is
  frequencies, `TWR_TWR1` is the master. Always check
  `references/schema.md` before guessing.
- **Verbose snake_case columns.** The FAA NASR layout uses extremely
  verbose field names verbatim. `airport_reference_point_latitude_formatted`,
  not `latitude`. `apt_latitude` and `apt_longitude` are the
  decimal-degree variants on the airport master.
- **Frequencies are text in multi-occurrence columns with `;`
  annotations.** Tower freqs live in
  `TWR_TWR3.frequencys_for_master_airport_use_only_and_sectorization_1..9`
  (with parallel `..._not_1..9` columns). Cells often look like
  `'120.95 ;SOUTH CMPLX'` — split on `;` to separate the numeric freq
  from its free-text qualifier (sectorization, hours, restricted-aircraft
  type, ramp-control designator). Without splitting, `float()` silently
  drops every annotated freq. AWOS station frequency is on
  `AWOS_AWOS1.station_frequency`, not on AWOS2 (which is just sensor
  info). To search across them you have to UNION across columns.
  Recipe in cookbook.
- **Frequency string formatting.** Stored as text like `'123.450'` —
  normalize the user's `'123.45'` to three decimals before equality.
- **Altitudes vary across tables.** `Class_Airspace.UPPER_VAL` is a
  string — sometimes integer feet MSL, sometimes `'GND'` / `'SFC'` /
  `'UNLTD'`. Coerce carefully; cast only after filtering out the
  non-numeric values.
- **AIXM operation tree** (special-use airspace). The `operation`
  column on `Airspace` encodes a multi-part composition like
  `(4:BASE,SUBTR,SUBTR,UNION)` — the polygon for designator X is **not**
  one row. To get the effective area, group rows by `designator` (in
  `sequenceNumber` order) and apply each operation in turn. Plain `BASE`
  rows are the simple case. Recipe in cookbook.
- **Class B/C airspace is multi-shelf.** A given Bravo airport has many
  `Class_Airspace` rows, each its own ring with its own floor/ceiling.
  Don't merge them before any altitude-bound logic.
- **Empty subtables.** Several record subtypes have zero rows in a given
  cycle. Check `COUNT(*)` before joining.
- **Lat/lon DMS variants.** Some columns store DMS-formatted text
  alongside decimal degrees. Pick the decimal-degree column
  (`*_decimal`, `apt_latitude`, `fix_latitude`, etc.) for math.
- **`MTR_MTRLINES.geometry` is plain WKT text**, not a SpatiaLite blob —
  must `GeomFromText(geometry)` and `SetSRID(..., 4326)` to use it
  spatially. There's also `MTR_MTRLINES.airwayGeom` (proper SpatiaLite
  blob with R-tree); prefer that.
- **`HPF_HP1` navaid linkage is `IDENT*TYPECODE`.** The
  `identifier_of_navaid_facility_used_to_provide_radial_or_bearing`
  column stores values like `'BNA*C'` — split on `*` to join `NAV_NAV1`.
  Holds at intersection fixes (not navaids) populate
  `fix_with_which_holding_is_associated` instead.
- **AIXM `AirspaceUsage.workingHours` mirrors `Airspace.operation`.**
  Composite-tree designators have `workingHours` like
  `'(2:TIMSH,NOTAM)'` — same shape as the `operation` column. Not
  human-readable hours; use `Airspace.note` for narrative schedules.
- **STARDP lat/lon are TEXT in `nasr.sqlite`**; DuckDB's `sqlite_scanner`
  errors on type sniffing. Use `SET GLOBAL sqlite_all_varchar=true;` and
  `CAST(... AS DOUBLE)`.
- **A handful of SUA polygons have non-closed rings** — DuckDB-spatial
  errors on read. Wrap with `ST_MakeValid` and gate on `ST_IsValid`.

## Pitfalls

- **Don't conflate Mode-C veil with Class B.** The 30-NM Mode C ring is
  *not* a Class_Airspace row — it's an FAR § 91.215 requirement, not
  airspace geometry. Aircraft at FL010 outside Bravo but inside the
  veil are Mode-C-required, not Bravo-clearance-required.
- **NASR is the regulatory snapshot, not real-time.** No NOTAMs, no
  TFRs, no closures, no winds, no aircraft. Don't claim a runway is
  "open" or an MOA is "active" from NASR alone.
- **Special-use airspace ≠ controlled airspace.** Two separate
  databases. A point can be inside both (e.g. Class E + a MOA).
- **The build is read-only.** Updates require a full refresh. Don't
  attempt to mutate the local `.sqlite` files.
- **Never auto-refresh.** A full rebuild downloads ~250 MB and takes
  5+ min. Always confirm with the user.

## Out of scope

- **FAA aircraft registry** (the Releasable Aircraft Database) — a
  separate dataset, not bundled here.
- **NOTAMs, TFRs, charts** — not in NASR.
- **Real-time anything** — NASR is a regulatory snapshot, not a feed.
