# Manual build (without scripts/setup.sh)

The recommended path is `./scripts/setup.sh --all`, which automates
everything below. This page is for users who'd rather do each step by
hand — or who are debugging a step that the script got wrong.

All paths use the env vars resolved by `scripts/load-config.sh`. To
populate them in your shell, run:

```bash
source scripts/load-config.sh
```

(or just substitute the defaults: `$NASR_DATA_DIR=~/data/faa/nasr`,
`$PROCESS_FAA_DATA_DIR=~/src/processFaaData`.)

## 1. Install prerequisites

| Tool | Purpose | macOS (Homebrew) | Debian/Ubuntu/WSL |
|---|---|---|---|
| Perl 5.34+ + cpanm | NASR-to-SQLite converter | `brew install perl cpanminus` | `sudo apt install perl cpanminus` |
| sqlite3 with `load_extension` | Apple's stock build omits it | `brew install sqlite` | `sudo apt install sqlite3` (already supports load_extension) |
| libspatialite + tools | SpatiaLite extension + CLI | `brew install libspatialite spatialite-tools` | `sudo apt install libsqlite3-mod-spatialite spatialite-bin` |
| GDAL ≥ 3.5 with Parquet | `ogr2ogr`, GeoParquet sidecars | `brew install gdal` | `sudo apt install gdal-bin python3-gdal` |
| DuckDB with spatial + parquet | Cross-format queries | `brew install duckdb` | Install from <https://duckdb.org> (apt lags) |
| `wget` | Subscription download | `brew install wget` | `sudo apt install wget` |

Verify GDAL has the Parquet driver:

```bash
ogrinfo --formats | grep -i parquet
```

## 2. Clone the build tool

The upstream `jlmcgraw/processFaaData` repo is dormant and currently
fails on macOS Tahoe / GDAL 3.12 / SpatiaLite 5. The patched fork is
the canonical source until upstream PR #17 merges:

```bash
git clone https://github.com/wiseman/processFaaData "$PROCESS_FAA_DATA_DIR"
cd "$PROCESS_FAA_DATA_DIR"
# If the fork branch isn't already default:
git checkout macos-tahoe-upstream-fixes
```

Confirm the patches are in:

```bash
git log --oneline -3
# Expect: "macOS portability fixes" / "Compatibility with GDAL 3.12 and SpatiaLite 5" / "Update FAA NASR API hostname"
```

## 3. Install Perl deps

```bash
cd "$PROCESS_FAA_DATA_DIR"
cpanm -L local --installdeps --notest .
```

## 4. Build the first cycle

```bash
mkdir -p "$NASR_DATA_DIR"
cd "$NASR_DATA_DIR"

# fetch the latest NASR subscription URL
url=$(cd "$PROCESS_FAA_DATA_DIR" && ./get_current_nasr_url.py)
wget --timestamping "$url"

# build (uses Perl + spatialite + ogr2ogr)
cd "$PROCESS_FAA_DATA_DIR"
./create_databases.sh "$NASR_DATA_DIR/$(basename "$url")"

# move sqlite outputs into the NASR dir
mv -f *.sqlite "$NASR_DATA_DIR/"

# build GeoParquet sidecars
cd "$NASR_DATA_DIR"
ogr2ogr -f Parquet -overwrite class_airspace.parquet \
  controlled_airspace_spatialite.sqlite Class_Airspace
ogr2ogr -f Parquet -overwrite special_use_airspace.parquet \
  special_use_airspace_spatialite.sqlite Airspace
ogr2ogr -f Parquet -overwrite obstacle.parquet \
  spatialite_nasr.sqlite OBSTACLE_OBSTACLE

# record the cycle date
echo "$(echo "$url" | sed -E 's/.*_Effective_([0-9-]+)\.zip/\1/')" \
  > "$NASR_DATA_DIR/CYCLE.txt"
```

## 5. Validate

```bash
./scripts/doctor.sh
```

Or run the row-count checks manually — see `references/refresh.md`
for baseline numbers.
