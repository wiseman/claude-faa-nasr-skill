#!/usr/bin/env bash
# scripts/refresh.sh — fetch + rebuild the local NASR cycle.
#
# Always confirm with the user before running this — it downloads
# ~250 MB and takes ~5 min. Doctor warnings about "cycle N days old"
# are the trigger.
#
# Usage:
#   scripts/refresh.sh              # fetch latest, build, validate
#   scripts/refresh.sh --skip-validate
#
# Env / config (resolved by load-config.sh):
#   NASR_DATA_DIR         — output dir (default ~/data/faa/nasr)
#   PROCESS_FAA_DATA_DIR  — clone of processFaaData (default ~/src/processFaaData)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=load-config.sh
. "$SCRIPT_DIR/load-config.sh"

VALIDATE=1
for arg in "$@"; do
  case "$arg" in
    --skip-validate) VALIDATE=0 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "refresh.sh: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

if [ ! -d "$PROCESS_FAA_DATA_DIR" ]; then
  echo "refresh.sh: build tool not found at $PROCESS_FAA_DATA_DIR" >&2
  echo "Run scripts/setup.sh --clone-build-tool first." >&2
  exit 1
fi

mkdir -p "$NASR_DATA_DIR"

echo "==> Resolving current NASR cycle URL"
url=$(cd "$PROCESS_FAA_DATA_DIR" && ./get_current_nasr_url.py)
zipname=$(basename "$url")
cycle_date=$(echo "$zipname" | sed -E 's/.*_Effective_([0-9-]+)\.zip/\1/')
echo "    cycle URL: $url"
echo "    cycle date: $cycle_date"

if [ -f "$NASR_DATA_DIR/CYCLE.txt" ]; then
  current=$(tr -d '[:space:]' < "$NASR_DATA_DIR/CYCLE.txt")
  if [ "$current" = "$cycle_date" ]; then
    echo "==> Already at cycle $cycle_date — nothing to refresh."
    exit 0
  fi
fi

echo "==> Downloading subscription zip into $NASR_DATA_DIR"
cd "$NASR_DATA_DIR"
if [ ! -f "$zipname" ]; then
  wget --timestamping "$url"
else
  echo "    $zipname already present, skipping download"
fi

echo "==> Building sqlite databases (this takes ~5 min)"
cd "$PROCESS_FAA_DATA_DIR"
./create_databases.sh "$NASR_DATA_DIR/$zipname"

echo "==> Moving sqlite outputs into $NASR_DATA_DIR"
for f in nasr spatialite_nasr controlled_airspace_spatialite special_use_airspace_spatialite; do
  mv -f "$PROCESS_FAA_DATA_DIR/$f.sqlite" "$NASR_DATA_DIR/"
done

echo "==> Building GeoParquet sidecars"
cd "$NASR_DATA_DIR"
if ogrinfo --formats 2>/dev/null | grep -qi parquet; then
  ogr2ogr -f Parquet -overwrite class_airspace.parquet \
    controlled_airspace_spatialite.sqlite Class_Airspace
  ogr2ogr -f Parquet -overwrite special_use_airspace.parquet \
    special_use_airspace_spatialite.sqlite Airspace
  ogr2ogr -f Parquet -overwrite obstacle.parquet \
    spatialite_nasr.sqlite OBSTACLE_OBSTACLE
else
  echo "    ogr2ogr lacks the Parquet driver — falling back to uv + geopandas"
  if ! command -v uv >/dev/null 2>&1; then
    echo "refresh.sh: uv not found. Run scripts/setup.sh --prereqs to install it." >&2
    exit 1
  fi
  "$SCRIPT_DIR/build-parquet-sidecars.py" "$NASR_DATA_DIR"
fi

echo "==> Updating CYCLE.txt"
echo "$cycle_date" > "$NASR_DATA_DIR/CYCLE.txt"

if [ "$VALIDATE" = 1 ]; then
  echo "==> Validating row counts"
  # Baselines from references/refresh.md (~5% slack tolerated; flag >10%).
  declare -a CHECKS=(
    "APT_APT 19500 nasr.sqlite"
    "APT_RWY 23000 nasr.sqlite"
    "NAV_NAV1 2600 nasr.sqlite"
    "FIX_FIX1 70000 nasr.sqlite"
    "AWY_AWY1 17000 nasr.sqlite"
    "ILS_ILS1 1600 nasr.sqlite"
    "TWR_TWR1 3500 nasr.sqlite"
    "OBSTACLE_OBSTACLE 600000 nasr.sqlite"
  )
  problems=0
  for entry in "${CHECKS[@]}"; do
    read -r table baseline db <<< "$entry"
    n=$("$SQLITE_BIN" "$NASR_DATA_DIR/$db" "SELECT COUNT(*) FROM $table;" 2>/dev/null || echo "0")
    if [ "$n" = "0" ]; then
      printf "    FAIL %-22s 0 rows (table missing or empty)\n" "$table"
      problems=$((problems + 1))
      continue
    fi
    pct=$(( n * 100 / baseline ))
    if [ "$pct" -lt 90 ]; then
      printf "    FAIL %-22s %s rows (%d%% of baseline %s)\n" "$table" "$n" "$pct" "$baseline"
      problems=$((problems + 1))
    else
      printf "    ok   %-22s %s rows (~%s baseline)\n" "$table" "$n" "$baseline"
    fi
  done
  if [ "$problems" -gt 0 ]; then
    echo "==> Validation failed — investigate the build log before relying on this cycle."
    exit 1
  fi
fi

echo "==> Refreshed to cycle $cycle_date"
