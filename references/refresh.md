# Refreshing the NASR build

The FAA publishes a new NASR cycle every 28 days. The local build is
regenerated from a downloaded subscription zip via
`$PROCESS_FAA_DATA_DIR`, plus `ogr2ogr` to produce the GeoParquet
sidecars.

**Always confirm with the user before refreshing.** A full rebuild is
~5 min and ~250 MB downloaded.

## TL;DR

```bash
./scripts/refresh.sh
```

The script reads paths from `scripts/load-config.sh`, downloads the
current cycle if it's newer than `$NASR_DATA_DIR/CYCLE.txt`, runs the
build, regenerates the parquet sidecars, updates `CYCLE.txt`, and
validates row counts against the baselines below.

If the script fails, the rest of this document is the troubleshooting
reference.

## The processFaaData repo

- **Upstream**: https://github.com/jlmcgraw/processFaaData (Perl-based
  NASR-to-SQLite converter, currently dormant)
- **Patched fork**: https://github.com/wiseman/processFaaData
- **Local clone**: `$PROCESS_FAA_DATA_DIR` (default `~/src/processFaaData`)

The upstream repo currently fails to build on macOS Tahoe / GDAL 3.12 /
SpatiaLite 5 due to several unrelated breakages — most importantly,
SpatiaLite 5's `CreateSpatialIndex()` aborts the SQL batch under the
default untrusted-schema guard, leaving the spatialite database with
empty geometry columns (silent failure). The patches are in
[jlmcgraw/processFaaData#17](https://github.com/jlmcgraw/processFaaData/pull/17).
Until that PR merges, use the patched fork — `scripts/setup.sh
--clone-build-tool` does this automatically.

If your local clone is a fresh upstream clone, switch to the fork's
patches:

```bash
cd "$PROCESS_FAA_DATA_DIR"
git remote add fork https://github.com/wiseman/processFaaData.git
git fetch fork
git merge --ff-only fork/macos-tahoe-upstream-fixes
```

Confirm the patches are present with `git log --oneline -3` — you
should see "macOS portability fixes", "Compatibility with GDAL 3.12 and
SpatiaLite 5", and "Update FAA NASR API hostname" in the recent
history. `scripts/doctor.sh` checks this for you.

## Check current local cycle

```bash
./scripts/doctor.sh
```

The doctor reports the cycle date and how many days old it is.

To check whether a newer cycle is published:

```bash
cd "$PROCESS_FAA_DATA_DIR" && ./get_current_nasr_url.py
```

Returns a URL like:

```
https://nfdc.faa.gov/.../28DaySubscription_Effective_YYYY-MM-DD.zip
```

The 28-day cadence is predictable — if local cycle date + 28 days is
in the past, there's at least one newer cycle.

## Validation baselines

`refresh.sh --skip-validate` skips this; otherwise the script bails
if any of these tables drops below 90 % of baseline.

```bash
$SQLITE_BIN "$NASR_DATA_DIR/nasr.sqlite" <<'SQL'
SELECT 'APT_APT' AS t, COUNT(*) FROM APT_APT
UNION ALL SELECT 'APT_RWY', COUNT(*) FROM APT_RWY
UNION ALL SELECT 'NAV_NAV1', COUNT(*) FROM NAV_NAV1
UNION ALL SELECT 'FIX_FIX1', COUNT(*) FROM FIX_FIX1
UNION ALL SELECT 'AWY_AWY1', COUNT(*) FROM AWY_AWY1
UNION ALL SELECT 'ILS_ILS1', COUNT(*) FROM ILS_ILS1
UNION ALL SELECT 'TWR_TWR1', COUNT(*) FROM TWR_TWR1
UNION ALL SELECT 'OBSTACLE_OBSTACLE', COUNT(*) FROM OBSTACLE_OBSTACLE;
SQL
```

Plausible row counts (typical 2026 cycle):

| Table | Approximate rows |
| --- | --- |
| APT_APT | ~19,500 |
| APT_RWY | ~23,000 |
| NAV_NAV1 | ~2,600 |
| FIX_FIX1 | ~70,000 |
| AWY_AWY1 | ~17,000 |
| ILS_ILS1 | ~1,600 |
| TWR_TWR1 | ~3,500 |
| OBSTACLE_OBSTACLE | ~600,000 |

Likewise for the airspace DBs:

```bash
$SQLITE_BIN "$NASR_DATA_DIR/controlled_airspace_spatialite.sqlite" \
  "SELECT CLASS, COUNT(*) FROM Class_Airspace GROUP BY CLASS;"
$SQLITE_BIN "$NASR_DATA_DIR/special_use_airspace_spatialite.sqlite" \
  "SELECT COUNT(*) FROM Airspace;"
```

Class_Airspace usually has B≈370 / C≈340 / D≈580 / E≈4,300 (~5,600
total). SUA `Airspace` ≈1,200. A drop >10 % in any of these is a red
flag — investigate the build log before relying on the new cycle.

## Build prerequisites

`scripts/doctor.sh` will tell you what's missing. The full table is
in `README.md`; this section calls out platform-specific gotchas.

### macOS

- **Homebrew sqlite with extension loading.** Apple's
  `/usr/bin/sqlite3` is built `SQLITE_OMIT_LOAD_EXTENSION`, so
  `.load mod_spatialite` silently fails — that breaks the entire
  spatialite-conversion step and you end up with NULL geometries.
  Install via `brew install sqlite`. The patched
  `create_databases.sh` picks `/opt/homebrew/opt/sqlite/bin/sqlite3`
  (Apple Silicon) or `/usr/local/opt/sqlite/bin/sqlite3` (Intel).
- **`mod_spatialite` full path.** The dyld search path for sqlite
  child processes does not include `/opt/homebrew/lib`, so a bare
  `load_extension('mod_spatialite')` fails. The patched
  `sqlite_to_spatialite.sql` tries multiple candidate paths.
- **GDAL ≥ 3.5 with Parquet driver** for `ogr2ogr` sidecars — verify
  with `ogrinfo --formats | grep -i parquet`. GDAL ≥ 3.12 also
  removes a flag conflict in the patched `create_databases.sh`.
- **Perl modules** from `cpanfile`. Install via
  `cpanm -L local --installdeps --notest .` (after
  `brew install cpanminus`).

### Linux (Debian/Ubuntu, including WSL)

The original processFaaData README documents Ubuntu setup. The
patches in PR #17 should be no-ops on Linux for the most part — they
either drop a flag (`-gt`), add a no-op-when-not-needed PRAGMA, or
extend an existing search list. The `cd && pwd` replacement for
`readlink -m` is functionally equivalent for this script's usage.

WSL behaves like Linux for the build — install with `apt-get`,
`mod_spatialite` resolves by bare name, and the build runs the same
way. DuckDB's apt package lags, so `setup.sh --prereqs` falls back to
the official tarball from duckdb.org.

**Parquet driver caveat.** Ubuntu's `gdal-bin` package does not ship
the GDAL Parquet driver, so `ogr2ogr -f Parquet` won't work.
`refresh.sh` detects this and dispatches to
`scripts/build-parquet-sidecars.py`, which uses pyogrio's bundled
GDAL (built with Parquet support) via `uv`. Output is byte-equivalent
to ogr2ogr's: same row counts, same WKB encoding, same GeoParquet 1.1
metadata. `setup.sh --prereqs` installs `uv` automatically on Linux.

### All platforms

- **`PRAGMA trusted_schema=ON`** is required for SpatiaLite 5+ to
  allow `CreateSpatialIndex()`'s use of `RTreeAlign()`. The patched
  `sqlite_to_spatialite.sql` includes this PRAGMA at the top.

## Failure modes

- **`get_current_nasr_url.py` returns the same URL you already have.**
  No newer cycle published. `scripts/refresh.sh` short-circuits and
  exits with no work done.
- **`create_databases.sh` fails on `parse_nasr.pl` import errors.**
  Likely Perl dependency drift. Re-run `scripts/setup.sh --perl-deps`
  (or, by hand, `cpanm -L local --installdeps --notest .` from inside
  `$PROCESS_FAA_DATA_DIR`).
- **`create_databases.sh` complains about `Saa_Sub_File` or
  `Shape_Files` not found.** The FAA occasionally renames or
  restructures the inner zip. Inspect the unpacked
  `NASR_28DaySubscription_Effective_<DATE>/` directory to find the
  current subdirectory names; patch the `find` calls in
  `create_databases.sh` if needed.
- **`ogr2ogr` reports "unable to find driver `Parquet`".** Install
  GDAL ≥ 3.5 with Parquet support: `brew install gdal` (recent
  Homebrew GDAL ships with Parquet enabled) or
  `apt install gdal-bin python3-gdal`. Verify with
  `ogrinfo --formats | grep -i parquet`.
- **DOF download fails** (`DAILY_DOF_DAT.ZIP`). The build pulls the
  daily obstacle file separately from the cycle. If the FAA URL is
  temporarily down, comment out that section in
  `create_databases.sh`; obstacles will then come from whatever
  DOF.DAT was last downloaded (and `OBSTACLE_OBSTACLE` will be
  slightly stale relative to the cycle).
- **Spatialite database has all-NULL geometry columns.** The
  SpatiaLite 5 untrusted-schema guard aborted the batch before the
  populating UPDATEs. Make sure your `sqlite_to_spatialite.sql`
  has the `PRAGMA trusted_schema=ON` line at the top — that's part
  of the patches in PR #17. `scripts/doctor.sh` warns when fork
  patches aren't detected.
- **Disk space.** Subscription zip + unpacked dir + four sqlite +
  three parquet ≈ 1.5 GB per cycle. Deleting prior cycles after a
  successful build keeps growth bounded.

## What's not in the refresh

- **FAA aircraft registry** — separate dataset, not part of NASR.
- **NOTAMs / TFRs** — not part of NASR; refreshing won't fetch them.
- **Charts** (sectional / IFR low/high) — separate FAA products.
