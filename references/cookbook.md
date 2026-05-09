# FAA NASR query cookbook

Templated recipes — fill in your filters / points / polygons. Paths
are written as env-var placeholders resolved by
`scripts/load-config.sh`:

| Placeholder | Default | Set by |
|---|---|---|
| `$NASR_DATA_DIR` | `~/data/faa/nasr` | `scripts/load-config.sh` |
| `$ADSB_PARQUET_DIR` | (unset) | user, only if they have an archive |
| `$SQLITE_BIN` | auto-detected sqlite3 with load_extension | `scripts/load-config.sh` |
| `$MOD_SPATIALITE_PATH` | auto-detected | `scripts/load-config.sh` |

How they expand depends on the execution context:

- **Shell + `sqlite3` CLI**: works directly. The shell expands `$VAR`
  before sqlite3 sees it. (Run `source scripts/load-config.sh` first.)
- **DuckDB**: env vars don't expand inside DuckDB string literals.
  For `read_parquet(...)`, `read_csv(...)`, etc., use the form
  `read_parquet(getenv('NASR_DATA_DIR') || '/foo.parquet')`. For
  `ATTACH`, which doesn't accept expressions, invoke duckdb from a
  shell that has the var exported: `duckdb -c "ATTACH
  '$NASR_DATA_DIR/foo.sqlite' AS n; ..."` — the shell substitutes
  before duckdb sees the SQL.
- **Python**: wrap with `os.path.expandvars("$NASR_DATA_DIR/foo")` —
  or, more robust, define once at the top:

  ```python
  import os
  NASR = os.environ.get("NASR_DATA_DIR", os.path.expanduser("~/data/faa/nasr"))
  ```

Each recipe notes which database to use.

Verify column names with `PRAGMA table_info(<table>)` before running — the
NASR layout has minor changes between cycles. See `schema.md` for the most
common columns per table.

---

## 1. Airport attribute lookup

Database: **`nasr.sqlite`**

```sql
SELECT location_identifier,
       official_facility_name,
       associated_city_name,
       associated_state_post_office_code,
       airport_elevation_nearest_tenth_of_a_foot_msl AS elev_ft,
       apt_latitude, apt_longitude
FROM APT_APT
WHERE location_identifier = ?ident;
```

For ICAO-style identifiers (`KLAX`), strip the leading `K` for US airports:
NASR's `location_identifier` uses the FAA 3-letter form (`LAX`, `MFR`),
not the ICAO prefix.

---

## 2. Aggregate over runways with text-numeric coercion

Database: **`nasr.sqlite`**. Many "numeric" columns are stored as text and
need `CAST` before aggregating; rows with empty strings need filtering.

```sql
-- Tallest runway-end elevations, joined to airport.
SELECT a.location_identifier, a.official_facility_name,
       a.associated_state_post_office_code,
       MAX(
         CAST(NULLIF(r.base_elevation_feet_msl_at_physical_runway_end, '') AS REAL),
         CAST(NULLIF(r.reciprocal_elevation_feet_msl_at_physical_runway_end, '') AS REAL)
       ) AS max_end_ft
FROM APT_RWY r
JOIN APT_APT a ON r.master_record_row_id = a.master_record_row_id
GROUP BY a.master_record_row_id
ORDER BY max_end_ft DESC NULLS LAST
LIMIT 25;
```

Same pattern works for runway length, width, etc.

---

## 3. Find a facility by frequency

Database: **`nasr.sqlite`**. Frequencies live in different tables and use
multi-occurrence columns. Normalize to three decimals before equality.

```sql
-- Tower frequencies (TWR_TWR3 has 9 occurrence columns + 9 "_not" columns).
WITH q(freq) AS (VALUES (printf('%.3f', 127.0)))
SELECT DISTINCT 'TWR' AS source,
       t.master_record_row_id,
       v.freq AS matched_freq
FROM TWR_TWR3 t,
     q,
     -- unpivot the 9 occurrence columns into rows
     (SELECT printf('%.3f', CAST(t.frequencys_for_master_airport_use_only_and_sectorization_1 AS REAL)) AS freq UNION ALL
      SELECT printf('%.3f', CAST(t.frequencys_for_master_airport_use_only_and_sectorization_2 AS REAL))      UNION ALL
      SELECT printf('%.3f', CAST(t.frequencys_for_master_airport_use_only_and_sectorization_3 AS REAL))      UNION ALL
      SELECT printf('%.3f', CAST(t.frequencys_for_master_airport_use_only_and_sectorization_4 AS REAL))      UNION ALL
      SELECT printf('%.3f', CAST(t.frequencys_for_master_airport_use_only_and_sectorization_5 AS REAL))      UNION ALL
      SELECT printf('%.3f', CAST(t.frequencys_for_master_airport_use_only_and_sectorization_6 AS REAL))      UNION ALL
      SELECT printf('%.3f', CAST(t.frequencys_for_master_airport_use_only_and_sectorization_7 AS REAL))      UNION ALL
      SELECT printf('%.3f', CAST(t.frequencys_for_master_airport_use_only_and_sectorization_8 AS REAL))      UNION ALL
      SELECT printf('%.3f', CAST(t.frequencys_for_master_airport_use_only_and_sectorization_9 AS REAL))) v
WHERE v.freq = q.freq;
```

In practice it's cleaner to write this in Python: load the columns and
flatten them programmatically rather than UNION-ing SQL.

```python
import sqlite3
con = sqlite3.connect('nasr.sqlite')
target = '127.000'
def norm(x):
    try: return f"{float(x):.3f}"
    except (ValueError, TypeError): return None

# TWR
cols = [f'frequencys_for_master_airport_use_only_and_sectorization_{i}' for i in range(1,10)]
rows = con.execute(f"SELECT master_record_row_id, {', '.join(cols)} FROM TWR_TWR3").fetchall()
for r in rows:
    if any(norm(v) == target for v in r[1:]):
        print('TWR', r[0])

# AWOS_AWOS1.station_frequency (single column, easier)
for r in con.execute("SELECT master_record_row_id, station_frequency FROM AWOS_AWOS1"):
    if norm(r[1]) == target: print('AWOS', r[0])

# COM_COM has communications_outlet_frequencies_1..16
# FSS_FSS frequencies are packed multi-occurrence text strings — substring match
# both by the same flatten-and-compare pattern.
```

Then `JOIN ... ON master_record_row_id = APT_APT.master_record_row_id` to
get airport names.

---

## 4. Spatial query — features near a point

Database: **`spatialite_nasr.sqlite`**

```bash
sqlite3 spatialite_nasr.sqlite
sqlite> .load mod_spatialite
```

```sql
-- Airports within 50 km of a point.
SELECT location_identifier, official_facility_name,
       ST_Distance(referenceGeom, MakePoint(?lon, ?lat, 4326), 1)/1852.0 AS nm
FROM APT_APT
WHERE PtDistWithin(referenceGeom, MakePoint(?lon, ?lat, 4326), 50000)
ORDER BY nm
LIMIT 20;
```

`PtDistWithin(geom, pt, meters)` triggers the R-tree. `ST_Distance(..., 1)`
returns ellipsoidal meters; divide by 1852 for nautical miles.

For nearest-neighbor at scale (faster than ORDER BY ST_Distance):

```sql
SELECT * FROM KNN
WHERE f_table_name = 'APT_APT'
  AND ref_geometry = MakePoint(?lon, ?lat, 4326)
  AND max_items = 5;
```

---

## 5. Reverse-geocode a lat/lon to NASR features

Multi-step: nearest airport, containing controlled airspace, containing
SUA, nearest navaid.

```sql
-- 5a. Nearest airport. spatialite_nasr.sqlite
SELECT location_identifier, official_facility_name,
       ST_Distance(referenceGeom, MakePoint(?lon, ?lat, 4326), 1)/1852.0 AS nm
FROM APT_APT
ORDER BY nm
LIMIT 1;
```

```sql
-- 5b. Containing controlled airspace. controlled_airspace_spatialite.sqlite
SELECT NAME, CLASS, LOWER_VAL, UPPER_VAL
FROM Class_Airspace
WHERE ST_Within(MakePoint(?lon, ?lat, 4326), GEOMETRY);
```

```sql
-- 5c. Containing special-use airspace. special_use_airspace_spatialite.sqlite
SELECT designator, name, lowerLimit, upperLimit
FROM Airspace
WHERE ST_Within(MakePoint(?lon, ?lat, 4326), GEOMETRY);
```

(Note: 5c returns per-part rows; you may need to evaluate the operation
tree to know whether the point is *truly* inside the effective polygon vs
inside a `SUBTR` hole. See § 7.)

```sql
-- 5d. Nearest navaid. spatialite_nasr.sqlite
SELECT navaid_facility_identifier, navaid_facility_type, navaid_facility_name,
       ST_Distance(geometry, MakePoint(?lon, ?lat, 4326), 1)/1852.0 AS nm
FROM NAV_NAV1
ORDER BY nm
LIMIT 1;
```

---

## 6. Get geometry as WKT for export

Any SpatiaLite database:

```sql
SELECT NAME, AsWKT(GEOMETRY) AS wkt
FROM Class_Airspace
WHERE NAME LIKE ?pattern;
```

Pipe to a file, then load in DuckDB / PostGIS / Shapely with
`ST_GeomFromText(...)`. Useful for one-off cross-format work without
regenerating sidecars.

---

## 7. Effective polygon for an SUA designator (operation tree)

Database: **`special_use_airspace_spatialite.sqlite`**.

Pull all rows for the designator, in sequence order:

```sql
SELECT sequenceNumber, operation, upperLimit, upperLimit_uom, lowerLimit, lowerLimit_uom,
       AsWKT(GEOMETRY) AS wkt
FROM Airspace
WHERE designator = ?designator
ORDER BY CAST(sequenceNumber AS INTEGER);
```

If `operation` is `BASE` and there's only one row, you're done — that's the
polygon.

For composite (`(N:OP1,OP2,...)`) parsing:

```python
import re
import shapely.wkt as W

def effective_shape(rows):
    """rows: list of (sequenceNumber:int, operation:str, wkt:str), sorted by seq."""
    # `operation` is the SAME on every row of a composite designator, like
    # '(4:BASE,SUBTR,SUBTR,UNION)'. Parse once.
    op_str = rows[0][1]
    if op_str == 'BASE':
        # Each row is a BASE; union them.
        shape = W.loads(rows[0][2])
        for _, _, w in rows[1:]:
            shape = shape.union(W.loads(w))
        return shape

    m = re.match(r'\((\d+):([A-Z,]+)\)', op_str)
    n, ops = int(m.group(1)), m.group(2).split(',')
    assert len(rows) == n == len(ops), (rows, op_str)

    shape = None
    for (_, _, wkt), op in zip(rows, ops):
        g = W.loads(wkt)
        if op == 'BASE':
            shape = g if shape is None else shape.union(g)
        elif op == 'UNION':
            shape = shape.union(g)
        elif op == 'SUBTR':
            shape = shape.difference(g)
        else:
            raise ValueError(f'unknown op {op!r}')
    return shape
```

The `upperLimit` and `lowerLimit` columns are **per row, parallel to the
operation list** — each composition part has its own altitude band. So
"is point P in airspace D between Y feet and Z feet" requires the
altitude check *inside* each part loop, not against the whole shape.

For the simple `BASE`-only majority of designators, you can ignore all
this and just `ST_Within(point, GEOMETRY)`.

---

## 8. Convert a SpatiaLite layer to GeoParquet (sidecar)

Run during refresh — see `refresh.md`. Single layer:

```bash
ogr2ogr -f Parquet -overwrite \
  $NASR_DATA_DIR/class_airspace.parquet \
  $NASR_DATA_DIR/controlled_airspace_spatialite.sqlite \
  Class_Airspace
```

Multi-layer (e.g. extract specific tables from the big spatialite NASR DB):

```bash
ogr2ogr -f Parquet -overwrite \
  $NASR_DATA_DIR/obstacle.parquet \
  $NASR_DATA_DIR/spatialite_nasr.sqlite \
  OBSTACLE_OBSTACLE
```

Requires GDAL ≥ 3.5 with Parquet enabled (`brew install gdal` on
macOS — Homebrew's recent GDAL ships with Parquet support).

---

## 9. DuckDB — generic NASR polygon × external parquet

Substitute the external parquet glob and the polygon filter.

```sql
INSTALL spatial; LOAD spatial;

WITH region AS (
  SELECT GEOMETRY AS geom,
         TRY_CAST(LOWER_VAL AS INTEGER) AS lower_ft,
         TRY_CAST(UPPER_VAL AS INTEGER) AS upper_ft,
         NAME, CLASS
  FROM '$NASR_DATA_DIR/class_airspace.parquet'
  WHERE <your filter>     -- e.g. CLASS='B' AND NAME LIKE '%SAN FRANCISCO%'
),
bb AS (
  SELECT MIN(ST_XMin(geom)) AS mnlon, MIN(ST_YMin(geom)) AS mnlat,
         MAX(ST_XMax(geom)) AS mxlon, MAX(ST_YMax(geom)) AS mxlat
  FROM region
)
SELECT t.*
FROM '/path/to/external/*.parquet' t, region r, bb
WHERE t.lat BETWEEN bb.mnlat AND bb.mxlat
  AND t.lon BETWEEN bb.mnlon AND bb.mxlon
  AND ST_Within(ST_Point(t.lon, t.lat), r.geom);
```

The bbox prefilter (`BETWEEN`) is the difference between a query that
returns in seconds and one that scans every parquet row group. Always
include it.

`TRY_CAST` survives non-numeric altitude values like `'GND'` / `'SFC'` /
`'UNLTD'` — they become `NULL`, so add explicit handling if those rows
matter.

---

## 10. NASR × ADS-B archive (named example of #9)

**Optional — only relevant if you have an ADS-B parquet archive.**
The convention this skill assumes is
`$ADSB_PARQUET_DIR/<files>.parquet`. Two common schemas (see
SKILL.md "Joining NASR × ADS-B parquet"):

- airplanes.live raw: `hex`, `flight`, `r`, `t`, `lat`, `lon`,
  `alt_baro`, `now`, `squawk` (VARCHAR)
- adsbx2parquet output: `icao24`, `callsign`, `registration`,
  `aircraft_type`, `latitude`, `longitude`, `baro_altitude`,
  `timestamp`, `squawk` (INTEGER)

The recipe below uses the adsbx2parquet column names. Adjust to
your schema.

```sql
-- DuckDB. Aircraft within an arbitrary NASR airspace polygon.
INSTALL spatial; LOAD spatial;

WITH region AS (
  SELECT GEOMETRY AS geom,
         TRY_CAST(LOWER_VAL AS INTEGER) AS lower_ft,
         TRY_CAST(UPPER_VAL AS INTEGER) AS upper_ft
  FROM '$NASR_DATA_DIR/class_airspace.parquet'
  WHERE <your filter>
),
bb AS (
  SELECT MIN(ST_XMin(geom)) AS mnlon, MIN(ST_YMin(geom)) AS mnlat,
         MAX(ST_XMax(geom)) AS mxlon, MAX(ST_YMax(geom)) AS mxlat
  FROM region
)
SELECT t.icao24, t.callsign, t.timestamp, t.latitude, t.longitude,
       t.baro_altitude, t.squawk
FROM '$ADSB_PARQUET_DIR/<files>' t,
     region r, bb
WHERE t.latitude  BETWEEN bb.mnlat AND bb.mxlat
  AND t.longitude BETWEEN bb.mnlon AND bb.mxlon
  AND t.baro_altitude BETWEEN COALESCE(r.lower_ft, 0)
                          AND COALESCE(r.upper_ft, 99999)
  AND ST_Within(ST_Point(t.longitude, t.latitude), r.geom);
```

For multi-day windows, pre-filter the ADS-B side first with
`adsbx2parquet --bbox <mnlat,mnlon,mxlat,mxlon> --time-range <…>` (see
adsb skill), then point DuckDB at the resulting smaller parquet — much
faster than scanning the full archive.

**Temporal alignment.** When querying historical ADS-B (>28 days old), the
*current* NASR cycle may not match the airspace that was effective at the
time. Note this when the gap could matter (boundary changes, frequency
reassignments, runway closures).

---

## 11. Bulk obstacle queries

Database: **`obstacle.parquet`** with DuckDB (faster than SpatiaLite for
wide aggregations over the 530k-row OBSTACLE table).

```sql
INSTALL spatial; LOAD spatial;

-- Tallest non-balloon obstacles by state.
SELECT state_identifier, obstacle_type, city_name,
       CAST(amsl_ht AS INTEGER) AS amsl_ft,
       CAST(agl_ht AS INTEGER)  AS agl_ft,
       obstacle_latitude, obstacle_longitude
FROM '$NASR_DATA_DIR/obstacle.parquet'
WHERE obstacle_type NOT LIKE '%BALLOON%'
ORDER BY amsl_ft DESC NULLS LAST
LIMIT 50;
```

```sql
-- Obstacles within a bbox, sorted by height.
SELECT *
FROM '$NASR_DATA_DIR/obstacle.parquet'
WHERE obstacle_latitude  BETWEEN ?mnlat AND ?mxlat
  AND obstacle_longitude BETWEEN ?mnlon AND ?mxlon
ORDER BY CAST(amsl_ht AS INTEGER) DESC;
```

---

## 12. Joining tables across NASR subjects

Most subject tables share `master_record_row_id` as the join key to the
master record of the **same subject** — i.e. `APT_RWY` joins to `APT_APT`,
`TWR_TWR3` joins to `TWR_TWR1`, etc. **Cross-subject joins** (tower → its
airport) usually go via an identifier field, not `master_record_row_id`:

```sql
-- Tower record → airport. TWR_TWR1 has its own master_record_row_id;
-- to find the served airport, use the airport identifier columns on TWR_TWR1
-- (e.g. associated_landing_facility_site_number / location_identifier).

SELECT a.location_identifier, a.official_facility_name, t.*
FROM TWR_TWR1 t
JOIN APT_APT a ON a.location_identifier = t.tower_facility_identifier;
```

(Verify the exact bridging column with `PRAGMA table_info` — it differs
between subject tables.)

For ILS → airport, the join is `ILS_ILS1.airport_identifier =
APT_APT.location_identifier`.

---

## 13. Quick sanity counts

```sql
-- nasr.sqlite. Run after a refresh; compare to baseline.
SELECT 'APT_APT' AS t, COUNT(*) FROM APT_APT
UNION ALL SELECT 'APT_RWY', COUNT(*) FROM APT_RWY
UNION ALL SELECT 'NAV_NAV1', COUNT(*) FROM NAV_NAV1
UNION ALL SELECT 'FIX_FIX1', COUNT(*) FROM FIX_FIX1
UNION ALL SELECT 'AWY_AWY1', COUNT(*) FROM AWY_AWY1
UNION ALL SELECT 'ILS_ILS1', COUNT(*) FROM ILS_ILS1
UNION ALL SELECT 'TWR_TWR1', COUNT(*) FROM TWR_TWR1
UNION ALL SELECT 'OBSTACLE_OBSTACLE', COUNT(*) FROM OBSTACLE_OBSTACLE;
```

Plausible row counts (typical 2026 cycle): APT_APT ~19,500 /
APT_RWY ~23,000 / NAV_NAV1 ~2,600 / FIX_FIX1 ~70,000 /
AWY_AWY1 ~17,000 / ILS_ILS1 ~1,600 / TWR_TWR1 ~3,500 /
OBSTACLE_OBSTACLE ~600,000. The FAA periodically renumbers /
re-issues records, so a ±5% drift between adjacent cycles is
normal.

A drop >10 % vs the previous cycle is a red flag — investigate before
relying on the new build.

---

# Worked challenges

Reference solutions for ten realistic NASR / NASR×ADS-B queries that
together exercise every major table. Each entry is a working recipe +
sample output trimmed to a few rows + the pitfalls that bit during
development. Use these as starting points; the recipes are
parameterizable.

> **macOS gotcha that affects most spatial recipes below:** Apple's
> `/usr/bin/sqlite3` is built with `SQLITE_OMIT_LOAD_EXTENSION`, so
> `.load mod_spatialite` silently fails. Either (a) call sqlite3 from
> Python with `con.enable_load_extension(True)` and
> `con.load_extension('$MOD_SPATIALITE_PATH')`, or
> (b) `brew install sqlite` and use `$SQLITE_BIN`.
> This applies to every recipe below that uses `mod_spatialite`.

---

## C1 — Wedding-cake decoder

For a single Class B airspace, list every shelf ordered innermost (smallest
lateral area) to outermost, with floor, ceiling, controlling agency, and
lateral area in NM². Multi-shelf Bravos have many rows in `Class_Airspace`
sharing `NAME` — do **not** merge them; each is its own ring with its own
floor/ceiling.

```python
# /// script
# requires-python = ">=3.11"
# ///
import sqlite3
con = sqlite3.connect("$NASR_DATA_DIR/controlled_airspace_spatialite.sqlite")
con.enable_load_extension(True)
con.load_extension("$MOD_SPATIALITE_PATH")
for row in con.execute("""
    SELECT IDENT, LOCAL_TYPE, NAME, LOWER_VAL, UPPER_VAL, COMM_NAME,
           ROUND(ST_Area(GEOMETRY, 1)/(1852.0*1852.0), 2) AS area_nm2
    FROM Class_Airspace
    WHERE NAME = 'SAN FRANCISCO CLASS B'    -- exact match, not LIKE
    ORDER BY area_nm2 ASC
"""):
    print(row)
```

Sample (SAN FRANCISCO, 17 shelves, total 2,126 NM², all ceilings 10,000 ft):

| floor | ceiling | area_nm² |
|---|---|---|
| 1600 | 10000 | 1.48 |
| 1500 | 10000 | 7.72 |
| 2100 | 10000 | 19.72 |
| ... | ... | ... |
| 7000 | 10000 | 661.36 |

**Pitfalls**
- macOS sqlite3 can't load extensions — use Python (see preface).
- `ST_Area(geom)` on EPSG:4326 returns degree²; pass `use_ellipsoid=1` (`ST_Area(GEOMETRY, 1)`) for m², then `/1852²` for NM².
- Don't `ST_Union` shelves before sorting — merging destroys the wedding-cake structure the question is asking about.
- `LOWER_VAL`/`UPPER_VAL` are TEXT and may be `'GND'`/`'SFC'`/`'UNLTD'` — coerce with `TRY_CAST`/`NULLIF` before arithmetic.
- `COMM_NAME` is empty/NULL for Class B in the 2026-04-16 build; the controlling TRACON lives in `TWR_TWR*`, not in this layer.
- Use exact `NAME = '... CLASS B'` rather than `LIKE '%LOS ANGELES%'` — the latter also catches Class C/D/E rings sharing the metro name.

---

## C2 — Cold-and-high IFR trap

Airports above 6,000 ft field elevation with at least one ILS-equipped runway
shorter than 6,000 ft AND a published glide slope ≥ 3.5°.

```sql
-- nasr.sqlite
SELECT
  a.location_identifier  AS apt_id,
  a.official_facility_name AS name,
  a.associated_state_post_office_code AS state,
  CAST(a.airport_elevation_nearest_tenth_of_a_foot_msl AS REAL)             AS field_elev_ft,
  r.runway_identification AS runway,
  CAST(r.runway_physical_runway_length_nearest_foot AS INTEGER)             AS rwy_len_ft,
  i1.ils_system_type      AS ils_class,
  i2.localizer_frequency_mhz                                                AS loc_freq_mhz,
  CAST(i3.glide_slope_angle_in_degrees_and_hundredths_of_degree AS REAL)    AS gs_angle_deg,
  CAST(r.base_elevation_feet_msl_at_physical_runway_end AS REAL)
    - CAST(r.reciprocal_elevation_feet_msl_at_physical_runway_end AS REAL) AS gradient_ft
FROM APT_APT a
JOIN ILS_ILS1 i1 ON i1.airport_identifier = a.location_identifier
JOIN APT_RWY r
  ON r.landing_facility_site_number = a.landing_facility_site_number
 AND (r.base_end_identifier = i1.ils_runway_end_identifier
   OR r.reciprocal_end_identifier = i1.ils_runway_end_identifier)
LEFT JOIN ILS_ILS2 i2
  ON i2.airport_site_number_identifier = i1.airport_site_number_identifier
 AND i2.ils_runway_end_identifier      = i1.ils_runway_end_identifier
 AND i2.ils_system_type                = i1.ils_system_type
JOIN ILS_ILS3 i3
  ON i3.airport_site_number_identifier = i1.airport_site_number_identifier
 AND i3.ils_runway_end_identifier      = i1.ils_runway_end_identifier
 AND i3.ils_system_type                = i1.ils_system_type
WHERE CAST(a.airport_elevation_nearest_tenth_of_a_foot_msl AS REAL) > 6000
  AND CAST(r.runway_physical_runway_length_nearest_foot AS INTEGER) < 6000
  AND CAST(i3.glide_slope_angle_in_degrees_and_hundredths_of_degree AS REAL) >= 3.5
ORDER BY field_elev_ft DESC;
```

Strict version returns **0 rows** in the 2026-04-16 cycle. Loosening the
runway-length cap surfaces **EGE** (Eagle County, CO) at 6,547 ft elev
with a 9,000 ft Rwy 07/25 ILS at GS 3.8°. The "obvious" candidates
(Telluride / Aspen / Leadville / Hayden) don't qualify because they have
LDA/LOC-only approaches and no `ILS_ILS3` glide-slope row.

**Pitfalls**
- ILS glide-slope angle is on `ILS_ILS3`, localizer freq is on `ILS_ILS2`, master record is `ILS_ILS1`.
- Join ILS sub-tables on (`airport_site_number_identifier`, `ils_runway_end_identifier`, `ils_system_type`) — runway-end alone isn't unique.
- `ILS_ILS1.airport_identifier` ↔ `APT_APT.location_identifier`. Bridge to `APT_RWY` via `landing_facility_site_number` and match the runway end.
- All NASR ILS columns are TEXT; cast to REAL/INT before numeric comparisons.
- LDA / LOC-only approaches have no `ILS_ILS3` row, so an INNER JOIN drops them silently — that's why steep-GS specialty approaches (LDA at TEX, ASE) don't appear.
- Runway gradient: `base_elevation - reciprocal_elevation` is positive when the base end is higher. APT_RWY also exposes `base_runway_end_gradient` if you want the FAA-computed value.

---

## C3 — Towered-airport frequency monogram

For all towered airports in a state, produce a tidy 4-column table
`(airport_identifier, frequency, use_code, notes)` by unpivoting
`TWR_TWR3`'s 9 (or 18, with `_not_*`) multi-occurrence columns AND
splitting each cell on `;` to separate the numeric frequency from its
free-text annotation.

A frequency cell looks like one of:
- `121.5` — bare numeric (most common)
- `'120.95 ;SOUTH CMPLX'` — sectorization
- `'119.8 ;HELICOPTERS'` — restricted to aircraft type
- `'129.4 ;TXL C7 0600L-2300L'` — ramp-control designator + hours
- `'372.2 ;SAMSO FLT OPS'` — operator-specific freq

Python is the cleaner driver — SQL would need `SUBSTR(... INSTR(... ';'))`
gymnastics across 18 columns:

```python
# nasr.sqlite. Example: California.
import sqlite3
from collections import defaultdict

con = sqlite3.connect("$NASR_DATA_DIR/nasr.sqlite")
STATE = 'CA'

freq_cols = ([f"frequencys_for_master_airport_use_only_and_sectorization_{i}"     for i in range(1, 10)]
           + [f"frequencys_for_master_airport_use_only_and_sectorization_not_{i}" for i in range(1, 10)])
use_cols  =  [f"frequency_use_{i}"                                                for i in range(1, 10)]

def parse(raw):
    """Returns (freq_str_to_3dp, annotation) or (None, _) if non-numeric/blank."""
    if raw is None: return None, ''
    s = str(raw).strip()
    if not s: return None, ''
    if ';' in s:
        head, tail = s.split(';', 1)
        s, ann = head.strip(), tail.strip()
    else:
        ann = ''
    try:    return f"{float(s):.3f}", ann
    except: return None, ann

towers = con.execute(f"""
  SELECT _id, terminal_communications_facility_identifier, official_airport_name
  FROM TWR_TWR1 WHERE associated_state_post_office_code = ?
""", (STATE,)).fetchall()

results = []  # list of (ident, name, freq, use, notes)
for twr1_id, ident, name in towers:
    rows = con.execute(f"""
      SELECT {', '.join(freq_cols + use_cols)}
      FROM TWR_TWR3 WHERE master_record_row_id = ?
    """, (twr1_id,)).fetchall()
    seen = set()
    for r in rows:
        for i, raw in enumerate(r[:18]):       # 18 freq cells per row
            f, ann = parse(raw)
            if f is None: continue
            use = (r[18 + (i % 9)] or '').strip()    # _N and _not_N share frequency_use_N
            key = (f, use, ann)
            if key in seen: continue            # dedupe within tower (mirror columns)
            seen.add(key)
            results.append((ident, name, f, use, ann))

results.sort(key=lambda x: (x[0], float(x[2])))
print(f"{len(results)} (airport, freq, use, notes) rows for {STATE}")
```

Sample — KSFO (no annotations, 9 rows):

| freq | use | notes |
|---|---|---|
| 113.700 | D-ATIS |  |
| 118.200 | CD PRE TAXI CLNC |  |
| 120.500 | LCL/P |  |
| 121.500 | EMERG |  |
| 121.800 | GND/P |  |
| 124.250 | GND/S |  |
| 269.100 | LCL/P |  |

Sample — KLAX (rich annotations, 22 rows including UHF military):

| freq | use | notes |
|---|---|---|
| 119.800 | LCL/P | HELICOPTERS |
| 120.350 | CD/P |  |
| 120.950 | LCL/P IC | SOUTH CMPLX |
| 121.400 | GND/P | WEST |
| 121.500 | EMERG |  |
| 121.650 | GND/P | NORTH-CMPLX |
| 121.750 | GND/P | SOUTH CMPLX |
| 129.400 | RAMP CTL | TXL C7 0600L-2300L |
| 133.800 | D-ATIS | ARR |
| 133.900 | LCL/P IC | NORTH CMPLX |
| 135.650 | D-ATIS | DEP |
| 243.000 | EMERG |  |
| 327.000 | GND/P |  |
| 372.200 | OPS | SAMSO FLT OPS |
| 379.100 | LCL/P IC | SOUTH CMPLX |

CA total: ~640 rows across ~75 facilities.

**Pitfalls**
- **Frequency cells contain `;` annotations** — split on `;` to separate freq (numeric) from notes (free text). Without this split, `float()` silently drops every annotated freq, producing dramatic undercounts (LAX falls from 22 → 5).
- The airport identifier on `TWR_TWR1` is `terminal_communications_facility_identifier`, NOT `master_airport_location_identifier` (that field holds the parent TRACON).
- `TWR_TWR3.master_record_row_id` joins to `TWR_TWR1._id` (rowid surrogate), not to any airport identifier.
- `_not_N` columns mirror the unsuffixed columns within a row — dedupe by `(freq, use, notes)` tuple per tower.
- `_not_N` reuses `frequency_use_N` (no `frequency_use_not_N` column exists) — pair using `(i % 9)`, not `(i % 9) + 1` (off-by-one is a common trap).
- A single tower can have multiple `TWR_TWR3` rows (LAX has 3) — the unpivot must iterate them all.
- `frequency_use_N` codes are FAA enums (`LCL/P`, `GND/P`, `CD/P`, `ATIS`, `D-ATIS`, `EMERG`, `RAMP CTL`, `OPS`, `SFRA`, `LCL/P IC`); annotations are free-text qualifiers — keep them in separate columns.
- State filter goes on `TWR_TWR1.associated_state_post_office_code`; no need to join `APT_APT`.

---

## C4 — MOA-dense airways

Top 10 Victor airways and jet routes by number of distinct MOAs they cross.

```python
# Combines spatialite_nasr.sqlite (airway segments) + special_use_airspace_spatialite.sqlite (MOAs)
# via DuckDB spatial. Skip-fail on a few invalid MOA rings.
import sqlite3, duckdb

# 1. Pull airway segments — AWY_AWYSEGMENTS has start/end lat-lon, build LINESTRINGs
con = sqlite3.connect('$NASR_DATA_DIR/spatialite_nasr.sqlite')
rows = con.execute("""
  SELECT airway_designation,
         navaid_facility_fix_latitude,  navaid_facility_fix_longitude,
         navaid_facility_fix_latitude2, navaid_facility_fix_longitude2
  FROM AWY_AWYSEGMENTS
  WHERE airway_designation GLOB 'V*' OR airway_designation GLOB 'J*'
""").fetchall()
con.close()

d = duckdb.connect()
d.execute("INSTALL spatial; LOAD spatial;")
d.execute("CREATE TABLE seg(designation VARCHAR, lat1 DOUBLE, lon1 DOUBLE, lat2 DOUBLE, lon2 DOUBLE)")
d.executemany("INSERT INTO seg VALUES (?,?,?,?,?)", rows)
d.execute("""CREATE TABLE awy AS
  SELECT designation, ST_MakeLine(ST_Point(lon1,lat1), ST_Point(lon2,lat2)) AS geom
  FROM seg WHERE lat1 IS NOT NULL AND lat2 IS NOT NULL""")

# 2. Pull MOA polygons via SpatiaLite as WKT, skip non-closed rings
con2 = sqlite3.connect('$NASR_DATA_DIR/special_use_airspace_spatialite.sqlite')
con2.enable_load_extension(True)
con2.load_extension('$MOD_SPATIALITE_PATH')
moa_rows = con2.execute(
  "SELECT designator, AsText(GEOMETRY) FROM Airspace "
  "WHERE suaType='MOA' AND GEOMETRY IS NOT NULL").fetchall()
con2.close()
d.execute("CREATE TABLE moa(designator VARCHAR, geom GEOMETRY)")
for des, wkt in moa_rows:
    try: d.execute("INSERT INTO moa VALUES (?, ST_MakeValid(ST_GeomFromText(?)))", [des, wkt])
    except: pass

# 3. Spatial join
print(d.execute("""
  WITH crossings AS (
    SELECT DISTINCT a.designation, m.designator AS moa
    FROM awy a JOIN moa m ON ST_Intersects(a.geom, m.geom))
  SELECT designation,
         CASE WHEN designation LIKE 'V%' THEN 'Victor' ELSE 'Jet' END AS kind,
         COUNT(*) AS n_moas,
         string_agg(moa, ', ' ORDER BY moa) AS moas
  FROM crossings GROUP BY designation
  ORDER BY n_moas DESC LIMIT 10
""").fetchdf().to_string(index=False))
```

Top 5 (2026-04-16): J50 (15 MOAs), J18 (13), J96 (12), J64 (11), J501/J65 (10 each).

**Pitfalls**
- Composition-tree simplification: ST_Intersects against every Airspace row treats SUBTR'd holes as MOA area, slightly inflating counts. ~27 % of designators are composite.
- `AWY_AWYSEGMENTS` has no real geometry column on this build; build LINESTRINGs from the `*_latitude`/`*_longitude` and `*_latitude2`/`*_longitude2` endpoint pairs.
- `airway_type` is mostly empty — classify Victor vs Jet by designation prefix (`V*`/`J*`).
- Filter SUA with `suaType='MOA'`; designators are AIXM-encoded with `M` prefix (e.g. `MEGLINAW`), not the chart name.
- ~50 SUA polygons have unclosed rings — DuckDB-spatial errors on read; insert row-by-row and skip failures (or `ST_MakeValid` in SpatiaLite first).
- Counts MOAs but not exposure — for "real" risk, weight by intersection length and altitude overlap with the airway's MEA.

---

## C5 — Cross-country obstacle profile

Tallest obstacles within 5 NM of the great-circle route between two
airports, with along-track and cross-track distance.

```python
# /// script
# requires-python = ">=3.11"
# dependencies = ["duckdb", "pandas"]
# ///
import math, os, sqlite3, duckdb, pandas as pd
NASR = os.environ.get("NASR_DATA_DIR", os.path.expanduser("~/data/faa/nasr"))
R_NM = 3440.065  # earth radius

# 1. Endpoints from APT_APT
con = sqlite3.connect(f"{NASR}/nasr.sqlite"); con.text_factory = bytes
def apt(ident):
    r = con.execute("SELECT apt_latitude, apt_longitude FROM APT_APT WHERE location_identifier=?", [ident]).fetchone()
    return float(r[0]), float(r[1])
(lat1,lon1), (lat2,lon2) = apt("SFO"), apt("JFK")

# 2. Great-circle interpolation, ~50 NM steps (linestring approximation)
def gc_interp(la1,lo1,la2,lo2,step=50.0):
    p1=(math.radians(la1),math.radians(lo1)); p2=(math.radians(la2),math.radians(lo2))
    d=2*math.asin(math.sqrt(math.sin((p2[0]-p1[0])/2)**2 + math.cos(p1[0])*math.cos(p2[0])*math.sin((p2[1]-p1[1])/2)**2))
    n=max(2,int(math.ceil(d*R_NM/step))+1); out=[]
    for i in range(n):
        f=i/(n-1); A=math.sin((1-f)*d)/math.sin(d); B=math.sin(f*d)/math.sin(d)
        x=A*math.cos(p1[0])*math.cos(p1[1]) + B*math.cos(p2[0])*math.cos(p2[1])
        y=A*math.cos(p1[0])*math.sin(p1[1]) + B*math.cos(p2[0])*math.sin(p2[1])
        z=A*math.sin(p1[0]) + B*math.sin(p2[0])
        out.append((math.degrees(math.atan2(z,math.hypot(x,y))), math.degrees(math.atan2(y,x))))
    return out
pts = gc_interp(lat1,lon1,lat2,lon2,50.0)

# 3. Bbox-prefilter obstacles via SQLite (text_factory=bytes avoids UTF-8 trap below)
lats,lons = zip(*pts); pad=0.15
rows = con.execute("""
  SELECT obstacle_latitude, obstacle_longitude, agl_ht, amsl_ht,
         obstacle_type, city_name, state_identifier
  FROM OBSTACLE_OBSTACLE
  WHERE CAST(obstacle_latitude AS REAL) BETWEEN ? AND ?
    AND CAST(obstacle_longitude AS REAL) BETWEEN ? AND ?
    AND obstacle_type <> 'BALLOON'""",
  [min(lats)-pad, max(lats)+pad, min(lons)-pad, max(lons)+pad]).fetchall()

def dec(v):
    if isinstance(v, bytes):
        try: return v.decode()
        except UnicodeDecodeError: return v.decode("latin-1")
    return v
def ti(v):
    if isinstance(v, int): return v
    s = dec(v); return int(s) if s not in (None, "") else None

obs_df = pd.DataFrame(
    [(float(dec(r[0])), float(dec(r[1])), ti(r[2]), ti(r[3]),
      dec(r[4]), dec(r[5]), dec(r[6])) for r in rows],
    columns=["lat","lon","agl_ht","amsl_ht","obstacle_type","city_name","state_identifier"])

# 4. Per-segment cross-track + along-track in DuckDB; clamp atd to [0, seg_len].
con = duckdb.connect()
con.register("obs_df", obs_df); con.execute("CREATE TABLE obs AS SELECT * FROM obs_df")

cum = [0.0]
for i in range(1, len(pts)):
    a, b = pts[i-1], pts[i]
    cum.append(cum[-1] + 2*R_NM*math.asin(math.sqrt(
        math.sin(math.radians(b[0]-a[0])/2)**2 +
        math.cos(math.radians(a[0]))*math.cos(math.radians(b[0]))
          *math.sin(math.radians(b[1]-a[1])/2)**2)))
segs = pd.DataFrame(
    [(i, pts[i][0], pts[i][1], pts[i+1][0], pts[i+1][1], cum[i], cum[i+1]-cum[i])
     for i in range(len(pts)-1)],
    columns=["idx","lat1","lon1","lat2","lon2","cum_start","seg_len"])
con.register("segs_df", segs); con.execute("CREATE TABLE segs AS SELECT * FROM segs_df")

con.execute("""
CREATE OR REPLACE MACRO gc_dist_nm(la1, lo1, la2, lo2) AS
  2*3440.065*asin(sqrt(pow(sin(radians(la2-la1)/2),2) +
    cos(radians(la1))*cos(radians(la2))*pow(sin(radians(lo2-lo1)/2),2)));
CREATE OR REPLACE MACRO gc_bear(la1, lo1, la2, lo2) AS
  atan2(sin(radians(lo2-lo1))*cos(radians(la2)),
        cos(radians(la1))*sin(radians(la2)) -
        sin(radians(la1))*cos(radians(la2))*cos(radians(lo2-lo1)));
""")

print(con.execute("""
WITH ps AS (
  SELECT o.rowid AS oid, s.idx, s.cum_start, s.seg_len,
         gc_dist_nm(s.lat1,s.lon1,o.lat,o.lon) AS d13,
         gc_bear(s.lat1,s.lon1,o.lat,o.lon)    AS th13,
         gc_bear(s.lat1,s.lon1,s.lat2,s.lon2)  AS th12
  FROM obs o, segs s),
xt AS (
  SELECT oid, idx, cum_start, seg_len, d13,
         asin(sin(d13/3440.065)*sin(th13-th12))*3440.065 AS xtd_signed,
         CASE WHEN abs(asin(sin(d13/3440.065)*sin(th13-th12))) >= d13/3440.065
              THEN d13
              ELSE acos(cos(d13/3440.065)/cos(asin(sin(d13/3440.065)*sin(th13-th12))))*3440.065
         END AS atd
  FROM ps),
clamp AS (
  SELECT oid,
         CASE WHEN atd<0 THEN d13 WHEN atd>seg_len THEN NULL ELSE abs(xtd_signed) END AS lat_nm,
         CASE WHEN atd<0 THEN cum_start WHEN atd>seg_len THEN cum_start+seg_len
              ELSE cum_start+atd END AS along_nm
  FROM xt),
best AS (
  SELECT oid, arg_min(along_nm, lat_nm) AS along_nm, min(lat_nm) AS lat_nm
  FROM clamp WHERE lat_nm IS NOT NULL GROUP BY oid)
SELECT round(b.along_nm,1) AS dist_dep_nm, round(b.lat_nm,2) AS lateral_nm,
       o.amsl_ht, o.agl_ht, o.obstacle_type, o.city_name, o.state_identifier
FROM best b JOIN obs o ON o.rowid=b.oid
WHERE b.lat_nm <= 5.0
ORDER BY o.amsl_ht DESC LIMIT 25;
""").fetchdf().to_string(index=False))
```

Sample (SFO→JFK, top 5 by AMSL, route 2,242 NM):

| dist_dep_nm | lateral_nm | amsl_ft | agl_ft | type | city | state |
|---|---|---|---|---|---|---|
| 156.2 | 0.56 | 10024 | 75 | TOWER | BRIDGEPORT | CA |
| 615.6 | 2.71 | 8725 | 100 | TOWER | DRY FORK | UT |
| 879.9 | 2.63 | 8647 | 237 | TOWER | BUFORD | WY |
| 814.5 | 0.08 | 8458 | 225 | TOWER | BUFORD | WY |
| 818.4 | 0.14 | 8135 | 260 | TOWER | BUFORD | WY |

Wyoming wind-farm clusters (~7700–8000 ft AMSL, 499 ft AGL) dominate the rest.

**Pitfalls**
- Rhumb-line interpolation skews ~150 NM north of the actual SFO→JFK great circle mid-route — always use spherical interpolation.
- DuckDB `ST_Buffer` is planar; buffering 5 NM in degrees stretches E-W at low lat and shrinks at high. Prefer per-segment cross-track distance over a degree buffer.
- `obstacle.parquet` contains a non-UTF-8 city name (CATAÑO, PR) that crashes DuckDB's varchar reader; pull through `nasr.sqlite` with `text_factory=bytes`, or skip varchar columns until after the numeric prefilter.
- Under `text_factory=bytes`, `agl_ht`/`amsl_ht` come back as `int` in some cycles (not bytes); the `ti(v)` helper above handles both.
- `obstacle_type='BALLOON'` rows reach 14k AGL and dominate any AMSL ranking — exclude up front.
- Cross-track without along-track clamping double-counts obstacles past segment ends; clamp `atd` to `[0, seg_len]` and dedupe per obstacle by `min(lateral)`.
- Units: 1 NM = 1852 m; earth radius = 3440.065 NM. Mixing km/NM in haversine is the most common silent error.

---

## C6 — Holding-pattern coverage map

Top 25 VOR-anchored holds by max altitude, with VOR identifier/freq,
inbound course (magnetic), leg length, and nearest ARTCC sector.

```python
# /// script
# requires-python = ">=3.11"
# ///
import math, sqlite3
con = sqlite3.connect("$NASR_DATA_DIR/spatialite_nasr.sqlite")
con.enable_load_extension(True)
con.load_extension("$MOD_SPATIALITE_PATH")

# 1. ARTCC centroids — spherical mean (handles dateline-wrapping oceanic ARTCCs).
pts = {}
for n, lat, lon in con.execute("""
    SELECT center_name, CAST(latitude AS REAL), CAST(longitude AS REAL)
    FROM ARB_ARB WHERE latitude<>'' AND longitude<>''"""):
    pts.setdefault(n, []).append((lat, lon))
con.execute("CREATE TEMP TABLE artcc_centroids(center_name TEXT, clat REAL, clon REAL)")
for name, ll in pts.items():
    x=y=z=0.0
    for lat,lon in ll:
        rlat,rlon = math.radians(lat), math.radians(lon)
        x += math.cos(rlat)*math.cos(rlon); y += math.cos(rlat)*math.sin(rlon); z += math.sin(rlat)
    n = len(ll); x/=n; y/=n; z/=n
    clat = math.degrees(math.atan2(z, math.hypot(x,y)))
    clon = math.degrees(math.atan2(y, x))
    con.execute("INSERT INTO artcc_centroids VALUES (?,?,?)", (name, clat, clon))

# 2. Holds at VORs. Hold "navaid" identifier is "IDENT*TYPECODE" (e.g. "BNA*C") — split on '*'.
# Altitudes: prefer all-aircraft column, fall back through speed-bracketed columns.
sql = """
WITH vor_holds AS (
  SELECT
    nv.navaid_facility_identifier AS vor_id,
    nv.frequency_the_navaid_transmits_on_except_tacan AS vor_freq_mhz,
    nv.navaid_facility_type_see_description AS vor_type,
    nv.name_of_navaid AS vor_name,
    CAST(nv.latitude AS REAL) AS vor_lat, CAST(nv.longitude AS REAL) AS vor_lon,
    hp.holding_pattern_name AS hold_name,
    hp.inbound_course AS inbound_course_mag,
    hp.leg_length_outbound_two_subfields_separated_by_a_slash_time_min AS leg_length,
    COALESCE(NULLIF(hp.holding_altitudes_for_all_aircraft, ''),
             NULLIF(hp.holding_alt_310_kt,''), NULLIF(hp.holding_alt_280_kt,''),
             NULLIF(hp.holding_alt_265_kt,''), NULLIF(hp.holding_alt_200_230_kt,''),
             NULLIF(hp.holding_alt_170_175_kt,'')) AS alt_range
  FROM HPF_HP1 hp
  JOIN NAV_NAV1 nv ON nv.navaid_facility_identifier =
       substr(hp.identifier_of_navaid_facility_used_to_provide_radial_or_bearing,
              1, instr(hp.identifier_of_navaid_facility_used_to_provide_radial_or_bearing, '*')-1)
  WHERE COALESCE(hp.fix_with_which_holding_is_associated, '') = ''
    AND nv.navaid_facility_type_see_description IN ('VOR','VOR/DME','VORTAC')
),
vh AS (
  SELECT *,
    CAST(CASE WHEN instr(alt_range,'/')>0 THEN substr(alt_range, instr(alt_range,'/')+1)
              ELSE alt_range END AS INTEGER) * 100 AS max_alt_ft
  FROM vor_holds WHERE COALESCE(alt_range,'') <> ''
),
ranked AS (
  SELECT vh.*, c.center_name AS artcc,
         ROW_NUMBER() OVER (PARTITION BY vor_id, hold_name
           ORDER BY Distance(MakePoint(vh.vor_lon, vh.vor_lat, 4326),
                             MakePoint(c.clon, c.clat, 4326))) AS rn
  FROM vh CROSS JOIN artcc_centroids c
)
SELECT vor_id, vor_freq_mhz, vor_type, vor_name, hold_name,
       inbound_course_mag, leg_length, alt_range, max_alt_ft, artcc
FROM ranked WHERE rn = 1
ORDER BY max_alt_ft DESC LIMIT 25;
"""
for r in con.execute(sql): print(r)
```

Sample (top 25 all peg out at FL450, the standard NASR upper bound):

| vor | freq | type | hold | inbnd° | leg | alt | nearest ARTCC |
|---|---|---|---|---|---|---|---|
| BNA | 114.1 | VORTAC | NASHVILLE *TN | 261 | /15 | 180/450 | ATLANTA |
| BLH | 117.4 | VORTAC | BLYTHE *CA | 88 | /12 | 250/450 | LOS ANGELES |
| ENE | 117.1 | VOR/DME | KENNEBUNK *ME | 224 | /16 | 170/450 | BOSTON |
| DRK | 114.1 | VORTAC | DRAKE *AZ | 250 | /16 | 180/450 | LOS ANGELES |
| DDY | 116.2 | VOR/DME | MUDDY MOUNTAIN *WY | 240 | /12 | 190/450 | DENVER |

**Pitfalls**
- `HPF_HP1` has no FK to `NAV_NAV1`; the navaid identifier is `IDENT*TYPECODE`, split on `*`.
- VOR-anchored holds set `fix_with_which_holding_is_associated` to empty — don't require it non-null.
- `holding_altitudes_for_all_aircraft` is empty for almost all VOR holds; coalesce across the speed-bracketed alt columns (`holding_alt_*_kt`).
- Altitude format is `low/high` in **hundreds of feet** (`180/450` = 18,000–45,000 ft).
- Naive `AVG(lat)/AVG(lon)` ARTCC centroids break for OAKLAND/ANCHORAGE OCEANIC (antimeridian wrap); use 3-D spherical mean or filter to CONUS-only.
- Inbound course is **magnetic**; NASR doesn't store a true-course version on `HPF_HP1`.

---

## C7 — ASOS-rich MTR corridor

Pick a military training route; list AWOS/ASOS within 10 NM of the route
line with sensor type, frequency, phone, station elevation, and the
station's terrain-relative MTR floor.

```sql
-- spatialite_nasr.sqlite. Run InitSpatialMetaData(1) once if needed.
.load $MOD_SPATIALITE_PATH

WITH mtr AS (
  SELECT route_identifier, route_type,
         SetSRID(GeomFromText(geometry), 4326) AS g
  FROM MTR_MTRLINES
  WHERE CAST(route_identifier AS INTEGER) = 178   -- IR-178 (W TX / SE NM)
),
floor AS (
  SELECT MIN(CAST(SUBSTR(s, 1, INSTR(s, ' AGL') - 1) AS INTEGER)) * 100 AS min_floor_agl_ft
  FROM (SELECT TRIM(segment_description_text_leading_up_to_the_point_maximum_of_4_o) AS s
        FROM MTR_MTR5
        WHERE CAST(route_identifier AS INTEGER) = 178
          AND segment_description_text_leading_up_to_the_point_maximum_of_4_o LIKE '__ AGL%')
)
SELECT a.wx_sensor_ident, a.wx_sensor_type, a.station_frequency,
       a.station_telephone_number,
       CAST(a.latitude AS REAL) AS lat, CAST(a.longitude AS REAL) AS lon,
       CAST(a.elevation AS REAL) AS station_elev_ft_msl,
       (SELECT min_floor_agl_ft FROM floor) AS mtr_min_floor_agl_ft,
       CAST(a.elevation AS REAL) + (SELECT min_floor_agl_ft FROM floor) AS floor_msl_at_station_ft,
       ST_Distance(m.g, MakePoint(CAST(a.longitude AS REAL), CAST(a.latitude AS REAL), 4326), 1)/1852.0 AS dist_nm
FROM mtr m, AWOS_AWOS1 a
WHERE a.latitude <> '' AND a.longitude <> ''
  AND ST_Distance(m.g, MakePoint(CAST(a.longitude AS REAL), CAST(a.latitude AS REAL), 4326)) < 0.18  -- coarse degree filter
  AND ST_Distance(m.g, MakePoint(CAST(a.longitude AS REAL), CAST(a.latitude AS REAL), 4326), 1) <= 18520
ORDER BY dist_nm;
```

Sample (IR-178, min floor 300 ft AGL, 3 stations within 10 NM):

| ident | type | freq | phone | elev | floor MSL @ stn | dist NM |
|---|---|---|---|---|---|---|
| E11 | AWOS-3 | 118.200 | 432-524-2471 | 3174 | 3474 | 4.32 |
| FST | ASOS | 118.525 | 432-336-7591 | 3011 | 3311 | 7.85 |
| PEQ | AWOS-3 | 118.175 | 432-445-3867 | 2613 | 2913 | 9.35 |

**Pitfalls**
- `MTR_MTRLINES` has TWO geometry columns: `airwayGeom` (proper SpatiaLite blob, R-tree-indexed — prefer this) and `geometry` (plain WKT text, lowercase `'linestring(...)'`, no index). The recipe above happens to use the WKT-text form via `GeomFromText`; switch to `airwayGeom` for index-friendly queries.
- `MTR_MTRLINES.route_identifier` is INTEGER; `route_identifier = '178'` (string) returns nothing. Cast or compare numerically.
- `AWOS_AWOS1.geometry` exists in the rebuilt spatialite layer (since 2026-04-16 cycle); replacing `MakePoint(...)` with `a.geometry` lets the R-tree fire. The recipe above pre-dates the spatial layer rebuild.
- MTR floors aren't a column — they're packed into `MTR_MTR5.segment_description_text_…` as `"03 AGL B 150 MSL"`, in **hundreds of feet**; parse and ×100.
- AGL floors mean the floor's MSL elevation depends on the station's terrain — `floor_msl_at_station = station_elev + floor_AGL`.
- `ST_Distance(g1, g2, 1)` (ellipsoidal meters) requires `InitSpatialMetaData(1)` to have run on the DB; otherwise use the degree filter as a coarse fallback.

---

## C8 — SID/STAR fixes inside SUA

For every published SID/STAR transition fix, find SUA polygons containing
it; report fix, procedure, SUA designator/name/type, activation hours.

```sql
-- DuckDB. Cross-source: STARDP fixes (nasr.sqlite) × SUA polygons (parquet)
-- × activation rules (special_use_airspace_spatialite.sqlite).
INSTALL sqlite; LOAD sqlite;
INSTALL spatial; LOAD spatial;
SET GLOBAL sqlite_all_varchar=true;     -- STARDP lat/lon are TEXT
ATTACH '$NASR_DATA_DIR/nasr.sqlite' AS n (TYPE SQLITE, READ_ONLY);
ATTACH '$NASR_DATA_DIR/special_use_airspace_spatialite.sqlite' AS sua
  (TYPE SQLITE, READ_ONLY);

WITH fixes AS (
  SELECT fix_navaid_airport_identifier AS fix_id,
         CAST(latitude AS DOUBLE) AS lat,
         CAST(longitude AS DOUBLE) AS lon,
         star_dp_computer_code AS procedure_name
  FROM n.STARDP_STARDP
  WHERE fix_navaid_airport_identifier IS NOT NULL
    AND latitude IS NOT NULL AND longitude IS NOT NULL
),
sua_poly AS (
  SELECT designator, name, suaType, ST_MakeValid(GEOMETRY) AS geom
  FROM '$NASR_DATA_DIR/special_use_airspace.parquet'
  WHERE GEOMETRY IS NOT NULL AND ST_IsValid(GEOMETRY)
),
usage AS (
  SELECT designator, MIN(workingHours) AS hours, MIN(statusActivation) AS status
  FROM sua.AirspaceUsage GROUP BY designator
)
SELECT f.fix_id, printf('%.4f', f.lat) AS fix_lat, printf('%.4f', f.lon) AS fix_lon,
       f.procedure_name,
       s.designator AS sua_designator,
       MIN(s.name) AS sua_name,
       CASE MIN(s.suaType)
         WHEN 'RA' THEN 'Restricted' WHEN 'MOA' THEN 'MOA'
         WHEN 'WA' THEN 'Warning' WHEN 'AA' THEN 'Alert'
         WHEN 'PA' THEN 'Prohibited' WHEN 'NSA' THEN 'NationalSecurity'
         ELSE MIN(s.suaType) END AS sua_type,
       COALESCE(MIN(u.hours), '') AS hours,
       COALESCE(MIN(u.status), '') AS status
FROM fixes f
JOIN sua_poly s ON ST_Within(ST_Point(f.lon, f.lat), s.geom)
LEFT JOIN usage u ON u.designator = s.designator
GROUP BY f.fix_id, f.lat, f.lon, f.procedure_name, s.designator
ORDER BY s.designator, f.fix_id, f.procedure_name
LIMIT 50;
```

Sample:

| fix | procedure | sua_designator | sua_name | type | hours |
|---|---|---|---|---|---|
| CYN | CYN.BOUNO5 | A220 | A-220 MCGUIRE AFB, NJ | Alert | TIMSH |
| LIFRR | DORRL2.DORRL | A291A | A-291A MIAMI, FL | Alert | TIMSH |
| SPS | SPS.MOTZA1 | A636 | A-636 WICHITA FALLS, TX | Alert | TIMSH |
| KRMAA | (no procedure code) | MABELBRAVO | ABEL BRAVO MOA, CA | MOA | (2:TIMSH,NOTAM) |

**Pitfalls**
- Operation-tree simplification: `ST_Within` against every Airspace row ignores `operation`. False positives possible if the fix sits inside a SUBTR'd hole. Strict version: walk rows per designator in `sequenceNumber` order applying BASE/UNION/SUBTR, then test.
- `STARDP_STARDP.latitude/longitude` are TEXT in `nasr.sqlite`; set `sqlite_all_varchar=true` and CAST, or DuckDB's sqlite scanner errors on type sniffing.
- A handful of SUA polygons are non-closed LinearRings — wrap with `ST_MakeValid` and gate on `ST_IsValid` or the spatial join aborts.
- `AirspaceUsage` is itself multi-row per designator (one row per composition part); collapse via GROUP BY designator. `workingHours` values like `(2:TIMSH,NOTAM)` mirror the `operation` tree — not human-readable hours; consult the AIXM `note` column for narrative schedules.
- `suaType` codes are AIXM 2-letter: `RA`, `MOA`, `WA`, `AA`, `PA`, `NSA`. Map them explicitly.
- Many STARDP rows have `star_dp_computer_code` blank (transition-only header rows); the same fix appears multiple times once per transition. De-dup on `(fix_id, sua_designator)` if you only want unique pairs.

---

## C9 — Bravo-bust candidates (NASR × ADS-B)

**Optional — requires an ADS-B parquet archive.** For one day of
ADS-B, find aircraft squawking 1200 inside any Class B shelf with
altitude bound to that shelf's floor/ceiling.

```sql
-- DuckDB. Replace the parquet path with the day you want.
INSTALL spatial; LOAD spatial;
WITH region AS (
  SELECT GEOMETRY AS geom, NAME,
         CASE WHEN LOWER_VAL IN ('GND','SFC') OR LOWER_VAL IS NULL THEN 0
              ELSE TRY_CAST(LOWER_VAL AS INTEGER) END AS lower_ft,
         CASE WHEN UPPER_VAL = 'UNLTD' OR UPPER_VAL IS NULL THEN 99999
              ELSE TRY_CAST(UPPER_VAL AS INTEGER) END AS upper_ft
  FROM '$NASR_DATA_DIR/class_airspace.parquet'
  WHERE CLASS = 'B'
),
bb AS (
  SELECT MIN(ST_XMin(geom)) AS mnlon, MIN(ST_YMin(geom)) AS mnlat,
         MAX(ST_XMax(geom)) AS mxlon, MAX(ST_YMax(geom)) AS mxlat
  FROM region
),
hits AS (
  SELECT t.hex AS icao24, t.r AS registration, t.flight AS callsign,
         t.t AS aircraft_type, r.NAME AS bravo_name, t.now AS ts, t.alt_baro
  FROM '$ADSB_PARQUET_DIR/alive_YYYY-MM-DD.parquet' t,
       region r, bb
  WHERE t.squawk = '1200'
    AND t.lat IS NOT NULL AND t.lon IS NOT NULL AND t.alt_baro IS NOT NULL
    AND t.lat BETWEEN bb.mnlat AND bb.mxlat
    AND t.lon BETWEEN bb.mnlon AND bb.mxlon
    AND t.alt_baro BETWEEN r.lower_ft AND r.upper_ft
    AND ST_Within(ST_Point(t.lon, t.lat), r.geom)
)
SELECT icao24, ANY_VALUE(registration) AS reg, ANY_VALUE(callsign) AS callsign,
       ANY_VALUE(aircraft_type) AS type, bravo_name,
       MIN(ts) AS first_inside, MAX(ts) AS last_inside,
       COUNT(*) AS n_reports, CAST(MEDIAN(alt_baro) AS INTEGER) AS median_alt_ft
FROM hits GROUP BY icao24, bravo_name ORDER BY n_reports DESC;
```

Sample (one day, 100 candidate (icao24, Bravo) pairs across NEW YORK,
SAN DIEGO, PHOENIX, LOS ANGELES, SAN FRANCISCO, HOUSTON, DALLAS, …):

| icao24 | reg | callsign | type | bravo | n_reports | median_alt |
|---|---|---|---|---|---|---|
| ae6ceb | 6056 | C6056 | H60 | SAN DIEGO CLASS B | 285 | 625 |
| ae4fe5 | 168149 | SHWK415 | H60 | SAN DIEGO CLASS B | 112 | 425 |
| a54d3c | N4402A | OXF1058 | P28A | PHOENIX CLASS B | 63 | 7497 |

**Pitfalls**
- The ADS-B archive has **two parquet schemas**: `alive_*.parquet`
  (airplanes.live raw — `hex/flight/r/t/lat/lon/alt_baro/now`, squawk
  VARCHAR) vs `adsbx-*.parquet` (legacy — `icao24/latitude/longitude/baro_altitude/timestamp`,
  squawk INTEGER). Match the recipe to the file you're querying.
- `LOWER_VAL`/`UPPER_VAL` are strings; coerce `'GND'`/`'SFC'`→0 and `'UNLTD'`/NULL→99999 BEFORE the BETWEEN.
- Apply altitude bound **per-shelf row**, not aggregated by NAME — Bravo shelves have differing floors/ceilings.
- Bbox prefilter is mandatory; without it ST_Within scans the full ~2 GB daily parquet.
- Candidates ≠ violations: cleared Bravo transitions, helicopter routes, and TFR/ATC discretions can leave 1200 squawk legitimately inside Bravo. Treat as leads only.
- `squawk='1200'` is a string compare — int 1200 won't match the airplanes.live schema.

---

## C10 — PJA communication coverage gap

For every parachute jump area, find the nearest published FSS or COM outlet;
flag PJAs whose nearest is >25 NM away.

```sql
-- macOS sqlite3 can't load mod_spatialite, and AWOS/PJA/FSS/COM have no geometry
-- column in spatialite_nasr.sqlite — use pure-SQL haversine. ~785k pairs, ~2 s.
ATTACH '$NASR_DATA_DIR/nasr.sqlite' AS n;

CREATE TEMP TABLE outlets AS
SELECT 'FSS' AS src,
       record_identifier_the_flight_service_stations_location_ident AS ident,
       CAST(latitude AS REAL) AS lat, CAST(longitude AS REAL) AS lon
FROM n.FSS_FSS
WHERE latitude <> '' AND longitude <> ''
UNION ALL
SELECT 'COM',
       communications_outlet_ident,
       CAST(latitude AS REAL), CAST(longitude AS REAL)
FROM n.COM_COM
WHERE latitude <> '' AND longitude <> ''
  AND CAST(latitude AS REAL) <> 0.0      -- filter (0,0) sentinels
  AND CAST(longitude AS REAL) <> 0.0;

CREATE TEMP TABLE pjas AS
SELECT _id AS pja_rid, pja_id, pja_drop_zone_name, pja_associated_city_name,
       pja_state_abbreviation_two_letter_post_office AS state,
       pja_maximum_altitude_allowed AS max_alt,
       CAST(latitude AS REAL) AS lat, CAST(longitude AS REAL) AS lon
FROM n.PJA_PJA1
WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

WITH pairs AS (
  SELECT p.pja_rid, p.pja_id, p.state, p.pja_drop_zone_name,
         p.pja_associated_city_name, p.max_alt, p.lat AS pja_lat, p.lon AS pja_lon,
         o.src, o.ident,
         3440.065 * 2 * ASIN(SQRT(
           POW(SIN(RADIANS(o.lat - p.lat)/2.0), 2) +
           COS(RADIANS(p.lat)) * COS(RADIANS(o.lat)) *
           POW(SIN(RADIANS(o.lon - p.lon)/2.0), 2))) AS dist_nm,
         ROW_NUMBER() OVER (PARTITION BY p.pja_rid ORDER BY
           3440.065 * 2 * ASIN(SQRT(
             POW(SIN(RADIANS(o.lat - p.lat)/2.0), 2) +
             COS(RADIANS(p.lat)) * COS(RADIANS(o.lat)) *
             POW(SIN(RADIANS(o.lon - p.lon)/2.0), 2)))) AS rk
  FROM pjas p CROSS JOIN outlets o
)
SELECT pja_id, state, pja_drop_zone_name, pja_associated_city_name, max_alt,
       MAX(CASE WHEN rk=1 THEN src END) AS n1_src,
       MAX(CASE WHEN rk=1 THEN ident END) AS n1_ident,
       MAX(CASE WHEN rk=1 THEN dist_nm END) AS n1_nm,
       MAX(CASE WHEN rk=2 THEN src END) AS n2_src,
       MAX(CASE WHEN rk=2 THEN ident END) AS n2_ident,
       MAX(CASE WHEN rk=2 THEN dist_nm END) AS n2_nm
FROM pairs WHERE rk <= 2
GROUP BY pja_rid, pja_id, state, pja_drop_zone_name, pja_associated_city_name, max_alt
ORDER BY n1_nm DESC LIMIT 25;
```

**688 PJAs total — 310 (45%) > 25 NM from any FSS/COM.** Top isolated:

| pja_id | state | drop_zone / city | n1_src | n1_ident | n1_nm |
|---|---|---|---|---|---|
| PGU005 | GU | AGAT BAY / Anderson | COM | 8NK (HI) | 3227.9 |
| PGU007 | GU | PAGAT | COM | 8NK | 3211.0 |
| PMP009 | MP | DANDAN DZ (Saipan) | COM | 8NK | 3131.5 |
| PVA008 | VA | / Virginia Beach | COM | PXT | 90.5 |
| PVA017 | VA | / Norfolk | COM | PXT | 84.3 |

Pacific territories dominate (no Pacific outlets in `FSS_FSS`/`COM_COM`).
The Virginia Tidewater cluster is the most striking real CONUS gap.

**Pitfalls**
- macOS `/usr/bin/sqlite3` can't `.load mod_spatialite` — see preface. With Homebrew sqlite the rebuilt spatialite layer (since 2026-04-16) DOES have `PJA_PJA1.geometry`, `FSS_FSS.geometry`, `COM_COM.geometry`, so a SpatiaLite version using `KNN` or `ST_Distance` is now possible and faster than the haversine cross-join above.
- `FSS_FSS` has three lat/lon pairs (decimal `latitude`/`longitude`, `airport_*_fss_on_arpt`, `*_when_fss_is_not_on_airport`); the decimal pair is populated for all 86 rows except 9 foreign FSSes — drop those.
- `COM_COM` has sentinel `latitude=0,longitude=0` rows (e.g. `ABR`, `ACH`) — filter `<> 0.0`.
- Order on the haversine NM directly, not on euclidean degrees — at mid-lat, a degree of longitude is much shorter than a degree of latitude.
- Spherical earth assumption (R=3440.065 NM) is fine for "more than 25 NM" thresholds (<0.5% error).
- "Outlet" here is FSS facilities + RCO/GCO outlets in `COM_COM`. Tower/approach/ARTCC/AWOS frequencies aren't included by design.
