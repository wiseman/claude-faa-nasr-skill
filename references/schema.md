# NASR schema cheat sheet

Compact reference for the local NASR databases. Field names are the FAA NASR
layout verbatim — verbose snake_case. **Always verify with
`PRAGMA table_info(<table>)` before relying on a column name** — the FAA
layout evolves between cycles.

## Conventions

- All four databases use **WGS84 / EPSG:4326**.
- Some lat/lon columns store DMS-formatted text; for math use the
  decimal-degree variants (`*_decimal`, `apt_latitude`, `fix_latitude`,
  navaid lat/lon, etc.).
- Frequencies are text strings, three decimal places (`'123.450'`).
  Multi-occurrence columns are common (`*_1`, `*_2`, … `*_9`).
- Altitudes are feet unless otherwise noted; "MSL" or "AGL" indicated in
  separate columns or by column suffix.
- Tables are joined via `master_record_row_id` to the master record of
  their subject prefix.

## Subject prefixes (nasr.sqlite)

### APT — Airports

- **`APT_APT`** — airport master record. ~20k rows.
  Useful columns: `master_record_row_id`, `location_identifier` (e.g.
  `KLAX`), `official_facility_name`, `associated_city_name`,
  `associated_state_post_office_code`, `apt_latitude`, `apt_longitude`,
  `airport_elevation_nearest_tenth_of_a_foot_msl`,
  `airport_ownership_type`, `airport_status_code`,
  `air_traffic_control_tower_located_on_airport`.
- **`APT_RWY`** — runways. ~24k rows. Joins via `master_record_row_id`.
  Useful: `runway_identification` (e.g. `04L/22R`),
  `runway_physical_runway_length_nearest_foot`,
  `runway_physical_runway_width_nearest_foot`, `runway_surface_type`,
  `base_end_runway_id`, `reciprocal_end_runway_id`,
  `base_elevation_feet_msl_at_physical_runway_end`,
  `reciprocal_elevation_feet_msl_at_physical_runway_end`,
  base/reciprocal latitude/longitude pairs for each runway end.
- `APT_ARS` — arresting systems.
- `APT_ATT` — attendance schedule.
- `APT_RMK` — remarks (free text).

### NAV — Navaids

- **`NAV_NAV1`** — master record. VORs, NDBs, TACANs, VORTACs, DMEs.
  Useful: `navaid_facility_identifier`, `navaid_facility_type`,
  `navaid_facility_name`, `navaid_facility_latitude`,
  `navaid_facility_longitude`, `navaid_radio_frequency`,
  `magnetic_variation`, `airway_identifier`.
- `NAV_NAV2..6` — fix-relative bearings, remarks, etc.

### FIX — Named Fixes / Waypoints

- **`FIX_FIX1`** — master record. ~66k rows.
  Useful: `fix_identifier`, `fix_state_post_office_code`, `fix_latitude`,
  `fix_longitude`, `icao_region_code`, `fix_type`,
  `fix_use_information_for_charting_purpose_only`.
- `FIX_FIX2..5` — usage subtypes, charting info.

### AWY — Airways

- **`AWY_AWY1`** — segment header / waypoints.
  Useful: `airway_designation` (e.g. `V23`, `J70`),
  `airway_type`, `point_sequence_number`, `point_identifier`,
  `point_latitude_formatted`, `point_longitude_formatted`.
- `AWY_AWY2..5` — additional segment data, MEAs/MAAs.
- spatialite extra: `AWY_AWYSEGMENTS` with `airwayGeom` linestring.

### ILS — Instrument Landing Systems

- **`ILS_ILS1`** — master record. ~1.6k rows.
  Useful: `airport_identifier` (joins to APT location_identifier),
  `runway_identification`, `ils_runway_end_id`,
  `ils_classification_code` (CAT I/II/III), `ils_localizer_frequency`,
  `glide_slope_angle`.
- `ILS_ILS2..6` — localizer, glide slope, marker beacons, DME components,
  each with own lat/lon.

### TWR — ATC Towers

- **`TWR_TWR1`** — master record per tower facility.
- **`TWR_TWR3`** — **frequencies**. Multi-occurrence schema: search across
  `frequencys_for_master_airport_use_only_and_sectorization_1..9` (and
  `..._not_1..9`) for the freq value, paired with `frequency_use_1..9`
  (use codes like `TWR`, `EMERG`, `GND`, `CLNC`, `ATIS`).
- `TWR_TWR3A` — additional frequency information.
- `TWR_TWR2`, `TWR_TWR4..9` — sectorization, hours, services.
- spatialite extras: geometry on `TWR_TWR1`
  (`airport_reference_pointGeometry`,
  `airport_surveillance_radarGeometry`,
  `direction_finding_antennaGeometry`).

### COM — Communications outlets

- **`COM_COM`** — outlets associated with FSSs. ~1k rows.
  Frequencies in `communications_outlet_frequencies_1..16` (multi-occurrence).
  Lat/lon in `associated_navaid_latitude` / `associated_navaid_longitude`.

### FSS — Flight Service Stations

- **`FSS_FSS`** — master record + frequencies.
  Frequencies are packed into long multi-occurrence text columns:
  `primary_fss_frequencies_used_60_occurences_of_40_characters_eac`,
  `airport_advisory_frequencies_20_occurences_of_6_characters_each`,
  `frequencies_used_by_the_communication_facility`. Parsing is awkward —
  treat as substring search rather than equality.

### AWOS — Automated Weather Observing Systems

- **`AWOS_AWOS1`** — master record.
  Useful: `wx_sensor_ident`, `wx_sensor_type` (AWOS-1, AWOS-3, ASOS, …),
  `station_frequency`, `station_telephone_number`,
  `second_station_frequency`, lat/lon. **Frequency is here, not in AWOS2.**
- `AWOS_AWOS2` — sensor remarks only (no frequency).

### OBSTACLE — Obstacle Database (DOF)

- **`OBSTACLE_OBSTACLE`** — ~530k rows.
  Useful: `obstacle_number`, `obstacle_type` (BLDG, TOWER, BALLOON,
  CRANE, …), `obstacle_latitude`, `obstacle_longitude` (decimal degrees),
  `agl_ht`, `amsl_ht`, `lighting`, `mark_indicator`, `verification_status`,
  `state_identifier`, `city_name`, `julian_date`, `quantity`.
  Note: tallest entries are typically tethered balloons; cap by
  `obstacle_type` if you want fixed structures only.

### MTR — Military Training Routes

- `MTR_MTR1` — route header (designator, type VR/IR/SR).
- `MTR_MTR2..6` — segments, altitudes, hours.
- spatialite extra: `MTR_MTRLINES.airwayGeom` linestring (proper geometry blob with R-tree).
- **Also** `MTR_MTRLINES.geometry` exists as a plain TEXT column holding
  lowercase WKT (`'linestring(...)'`) — use `GeomFromText()` +
  `SetSRID(..., 4326)` if you reference that column. The `airwayGeom`
  column is the spatially-indexed proper-blob form.
- **`route_identifier` is INTEGER** in MTR_MTRLINES and several MTR_MTRn
  tables; `route_identifier = '178'` (string compare) returns nothing —
  cast or compare numerically.
- **Floor altitudes aren't a column** — they're packed into
  `MTR_MTR5.segment_description_text_leading_up_to_the_point_maximum_of_4_o`
  as `'03 AGL B 150 MSL'` (in **hundreds of feet**). Parse with `SUBSTR`
  + `INSTR ' AGL'` and multiply by 100.

### ARB — ARTCC Boundaries

- `ARB_ARB` — boundary points (sequence per ARTCC sector).

### HPF — Holding Patterns

- `HPF_HP1..4` — published holds at fixes/navaids, with inbound course,
  legs, altitudes, speed limits.
- **Navaid linkage**:
  `identifier_of_navaid_facility_used_to_provide_radial_or_bearing`
  stores values as `'IDENT*TYPECODE'` (e.g. `'BNA*C'` — Nashville
  VORTAC). Split on `*` to join `NAV_NAV1.navaid_facility_identifier`.
- **VOR-anchored holds set `fix_with_which_holding_is_associated` to
  empty.** Don't filter holds with `IS NOT NULL` on the fix column or
  you only get intersection-anchored holds.
- **Inbound course is magnetic**, not true. NASR doesn't store a
  true-course version on `HPF_HP1`.
- **Altitude format** is `'low/high'` in **hundreds of feet**, e.g.
  `'180/450'` = 18,000–45,000 ft MSL. The all-aircraft column is empty
  for most rows; coalesce across the speed-bracketed columns
  (`holding_alt_310_kt`, `holding_alt_280_kt`, `holding_alt_265_kt`,
  `holding_alt_200_230_kt`, `holding_alt_170_175_kt`).

### STARDP — SIDs / STARs

- `STARDP_STARDP` — procedure transition points. One row per fix in
  procedure.

### Other prefixes (smaller tables)

- `AFF_*` — airport facility info.
- `ATS_*` — Air Traffic Service routes.
- `LID_*` — aerodrome lighting.
- `PFR_*` — preferred routes.
- `PJA_*` — parachute jump areas.
- `WXL_*` — weather/notice locations.

## Spatial layers in spatialite_nasr.sqlite

R-tree indexes are auto-named `idx_<TABLE>_<GEOMCOL>` and used
automatically when filtering with `ST_Intersects` / `ST_Within` /
`PtDistWithin` / `MbrIntersects`. Inventory:

| Table | Geometry column | Type |
| --- | --- | --- |
| `APT_APT` | `referenceGeom` | POINT |
| `APT_RWY` | `runwayGeom`, `baseGeom`, `reciprocalGeom`, `baseDisplacedThresholdGeom`, `reciprocalDisplacedThresholdGeom` | LINESTRING / POINT |
| `NAV_NAV1` | `geometry` | POINT |
| `FIX_FIX1` | `geometry` | POINT |
| `AWY_AWY2`, `AWY_AWY3` | `geometry` | POINT |
| `AWY_AWYSEGMENTS` | `airwayGeom` | LINESTRING |
| `ILS_ILS2..5` | `geometry` | POINT |
| `OBSTACLE_OBSTACLE` | `obstacleGeom` | POINT |
| `TWR_TWR1` | `airport_reference_pointGeometry`, `airport_surveillance_radarGeometry`, `direction_finding_antennaGeometry` | POINT |
| `TWR_TWR7` | `airportGeometry` | POINT |
| `MTR_MTRLINES` | `airwayGeom` | LINESTRING |
| `MTR_MTR5` | `geometry` | POINT |
| `ARB_ARB` | `geometry` | POINT |
| `HPF_HP1` | `fixGeometry`, `navaidGeometry` | POINT |
| `WXL_WXL` | `geometry` | POINT |
| `COM_COM` | `geometry` | POINT |
| `FSS_FSS` | `geometry` | POINT |
| `AWOS_AWOS1` | `geometry` | POINT |
| `STARDP_STARDP` | `geometry` | POINT |
| `PJA_PJA1` | `geometry` | POINT |
| `AFF_AFF1`, `AFF_AFF3` | `geometry` | POINT |
| `ATS_ATS2` | `geometry` | (line) |

To enumerate authoritatively for a given build:

```sql
SELECT f_table_name, f_geometry_column, geometry_type
FROM geometry_columns;
```

## Class_Airspace (controlled_airspace_spatialite.sqlite)

Single table, one row per airspace **shelf** (Bravo/Charlie are multi-row
wedding cakes).

| Column | Notes |
| --- | --- |
| `OGC_FID` | row id |
| `IDENT` | identifier |
| `NAME` | airport / facility name (e.g. `LOS ANGELES`) |
| `CLASS` | `B`, `C`, `D`, `E` |
| `TYPE_CODE`, `LOCAL_TYPE` | sub-classification |
| `LOWER_VAL`, `LOWER_UOM`, `LOWER_DESC`, `LOWER_CODE` | floor (string; `'GND'` / `'SFC'` / integer ft) |
| `UPPER_VAL`, `UPPER_UOM`, `UPPER_DESC`, `UPPER_CODE` | ceiling (string; sometimes `'UNLTD'`) |
| `MIL_CODE` | military flag |
| `COMM_NAME` | controlling agency |
| `WKHR_CODE`, `WKHR_RMK` | working hours |
| `LEVEL`, `SECTOR`, `ONSHORE`, `EXCLUSION` | classification flags |
| `DST`, `GMTOFFSET` | timezone info |
| `SHAPE_Leng`, `SHAPE_Area` | metadata from source shapefile |
| `GEOMETRY` | `MULTIPOLYGON`, EPSG:4326 |

Distribution as of the 2022 build (sanity baseline):
B=365 / C=326 / D=576 / E=4314, total 5,581 rows.

Multi-shelf airspaces share `NAME` across rows; **don't merge geometry
before applying altitude logic** — each shelf has its own floor/ceiling.

## Special-use Airspace (special_use_airspace_spatialite.sqlite, AIXM)

AIXM 5.1-style schema. Tables:

| Table | Role | ~Rows |
| --- | --- | --- |
| `Airspace` | The polygons. Composed via `operation` tree. | 1,475 |
| `AirspaceUsage` | Activation rules / hours linked to an Airspace. | 1,471 |
| `AirTrafficControlService` | Controlling ATC service. | 2,845 |
| `InformationService` | NOTAM / advisory link. | 1,597 |
| `OrganisationAuthority` | Designating authority. | 2,350 |
| `Unit` | Operating unit. | 2,417 |
| `RadioCommunicationChannel` | Frequencies tied to services. | 1,233 |
| `GeoBorder` | Borders. | 1 |

### `Airspace` important columns

- `gml_id` — stable per record
- `identifier` — UUID
- `designator` — `A211`, `R-2508`, `W-470`, etc.
- `name` — `A-211 DOTHAN, AL`
- `suaType` — AIXM 2-letter code (see below)
- `operation` — composition tree, see below
- `sequenceNumber` — order within a multi-part composition
- `upperLimit`, `upperLimit_uom`, `upperLimitReference` — ceiling per part
- `lowerLimit`, `lowerLimit_uom`, `lowerLimitReference` — floor per part
- `GEOMETRY` — per-part polygon (EPSG:4326)
- `note` — free text; the place to look for narrative activation hours

### `suaType` codes

| Code | Meaning |
| --- | --- |
| `RA` | Restricted Area |
| `MOA` | Military Operations Area |
| `WA` | Warning Area |
| `AA` | Alert Area |
| `PA` | Prohibited Area |
| `NSA` | National Security Area |

Filter by `suaType = 'MOA'` etc. The chart name (e.g. "EGLIN A MOA") is
in `name`; the AIXM-encoded designator (e.g. `MEGLINAW`) is in
`designator`.

### `AirspaceUsage.workingHours` mirrors the operation tree

Multi-part designators have `workingHours` strings shaped like the
`operation` column — `'(2:TIMSH,NOTAM)'`, `'(4:CONT,TIMSH,...)'`, etc.
These are codes per composition part, not human-readable schedules. For
narrative hours, look at `Airspace.note`. Single-part designators just
have `'TIMSH'` or `'CONT'` as a plain string.

### The `operation` column (set algebra)

Multi-part SUA encodes a composition:

- `BASE` — this row is a base polygon (single-row designator, the easy case).
- `(2:BASE,SUBTR)` — two rows; row 1 is the base, row 2 is subtracted (a hole).
- `(2:BASE,UNION)` — two-row union.
- `(4:BASE,SUBTR,SUBTR,UNION)` — four-row composition: base + last,
  minus rows 2 and 3.
- The number prefix (`4:`) is the count of parts; entries are positional
  relative to `sequenceNumber`.

To get the effective polygon for a designator: select all rows for that
designator in `sequenceNumber` order, walk the operation list, and apply
each operation. `upperLimit` / `lowerLimit` are per-row, parallel to the
operation list — i.e. each composition part has its own altitude band, so
applying altitude filters before composing is wrong.

Recipe: `cookbook.md` § 7.

Distribution of operation kinds: ~1,073 `BASE`-only rows (~73 % of
designators are simple); the rest involve composition.
