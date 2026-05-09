#!/usr/bin/env bash
# scripts/doctor.sh — diagnose a faa-nasr-skill install.
#
# Reports problems and exits non-zero if any required piece is
# missing. Never modifies state.
#
# Usage:
#   scripts/doctor.sh             # full report
#   scripts/doctor.sh --quiet     # only print on problems
#   scripts/doctor.sh --paths     # print resolved paths and exit 0

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=load-config.sh
. "$SCRIPT_DIR/load-config.sh"

QUIET=0
PATHS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --quiet|-q) QUIET=1 ;;
    --paths) PATHS_ONLY=1 ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "doctor.sh: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

if [ "$PATHS_ONLY" = 1 ]; then
  echo "NASR_DATA_DIR=$NASR_DATA_DIR"
  echo "PROCESS_FAA_DATA_DIR=$PROCESS_FAA_DATA_DIR"
  echo "SQLITE_BIN=$SQLITE_BIN"
  echo "MOD_SPATIALITE_PATH=$MOD_SPATIALITE_PATH"
  echo "ADSB_PARQUET_DIR=${ADSB_PARQUET_DIR:-(unset)}"
  exit 0
fi

PROBLEMS=()
WARNINGS=()

emit_ok()   { [ "$QUIET" = 1 ] || printf "  ok   %s\n" "$1"; }
emit_warn() { WARNINGS+=("$1"); printf "  warn %s\n" "$1"; }
emit_fail() { PROBLEMS+=("$1"); printf "  FAIL %s\n" "$1"; }
section()   { [ "$QUIET" = 1 ] || printf "\n== %s ==\n" "$1"; }

section "Resolved paths"
[ "$QUIET" = 1 ] || {
  printf "  NASR_DATA_DIR        = %s\n" "$NASR_DATA_DIR"
  printf "  PROCESS_FAA_DATA_DIR = %s\n" "$PROCESS_FAA_DATA_DIR"
  printf "  SQLITE_BIN           = %s\n" "$SQLITE_BIN"
  printf "  MOD_SPATIALITE_PATH  = %s\n" "$MOD_SPATIALITE_PATH"
  printf "  ADSB_PARQUET_DIR     = %s\n" "${ADSB_PARQUET_DIR:-(unset; ADS-B joins disabled)}"
}

section "Tools"
need() {
  local tool=$1 hint=$2 path
  if path=$(command -v "$tool" 2>/dev/null); then
    emit_ok "$tool found at $path"
  else
    emit_fail "$tool missing — $hint"
  fi
}
need perl   "install via brew/apt (perl)"
need cpanm  "install via brew install cpanminus / apt install cpanminus"
need wget   "install via brew/apt"
need ogr2ogr "install GDAL >= 3.5 (brew install gdal / apt install gdal-bin)"
need duckdb "install via brew install duckdb / official duckdb tarball on Linux"
need git    "install git"

section "GeoParquet sidecar build path"
if command -v ogrinfo >/dev/null 2>&1 && ogrinfo --formats 2>/dev/null | grep -qi parquet; then
  emit_ok "ogr2ogr has the Parquet driver — sidecars built directly"
elif command -v uv >/dev/null 2>&1; then
  emit_ok "uv present — sidecars will be built via scripts/build-parquet-sidecars.py (Ubuntu fallback)"
else
  emit_fail "Need either GDAL with Parquet driver or uv (https://astral.sh/uv/install.sh)"
fi

section "sqlite + mod_spatialite"
if [ -n "$SQLITE_BIN" ] && command -v "$SQLITE_BIN" >/dev/null 2>&1 || [ -x "$SQLITE_BIN" ]; then
  err=$("$SQLITE_BIN" :memory: ".load this_path_does_not_exist_xyz" 2>&1 || true)
  case "$err" in
    *"not authorized"*|*"omitted"*)
      emit_fail "$SQLITE_BIN was built without load_extension support (Apple stock sqlite). brew install sqlite and re-run." ;;
    *)
      emit_ok "$SQLITE_BIN supports load_extension" ;;
  esac
else
  emit_fail "SQLITE_BIN ($SQLITE_BIN) not executable"
fi

if [ -e "$MOD_SPATIALITE_PATH" ] || [ "$MOD_SPATIALITE_PATH" = "mod_spatialite" ]; then
  err=$("$SQLITE_BIN" :memory: ".load $MOD_SPATIALITE_PATH" 2>&1 || true)
  if [ -z "$err" ]; then
    emit_ok "mod_spatialite loads via $MOD_SPATIALITE_PATH"
  else
    emit_fail "mod_spatialite failed to load via $MOD_SPATIALITE_PATH: $err"
  fi
else
  emit_fail "mod_spatialite not found at $MOD_SPATIALITE_PATH (install libspatialite / spatialite-tools)"
fi

section "Build tool ($PROCESS_FAA_DATA_DIR)"
if [ -d "$PROCESS_FAA_DATA_DIR/.git" ]; then
  emit_ok "processFaaData clone present"
  if [ -x "$PROCESS_FAA_DATA_DIR/get_current_nasr_url.py" ] \
     && [ -x "$PROCESS_FAA_DATA_DIR/create_databases.sh" ]; then
    emit_ok "build entry points executable"
  else
    emit_warn "expected scripts in $PROCESS_FAA_DATA_DIR are missing or non-executable"
  fi
  if [ -d "$PROCESS_FAA_DATA_DIR/local" ]; then
    emit_ok "Perl deps installed (local/ dir present)"
  else
    emit_warn "no local/ dir — run 'cpanm -L local --installdeps --notest .' inside $PROCESS_FAA_DATA_DIR"
  fi
  # Check that the macos-tahoe / SpatiaLite-5 patches are in.
  # Capture into a var first — `git log | grep -q` under pipefail
  # returns 141 (SIGPIPE) when grep exits early on a match.
  recent_log=$(cd "$PROCESS_FAA_DATA_DIR" && git log --oneline -20 2>/dev/null || true)
  if echo "$recent_log" | grep -qiE "$FAA_NASR_FORK_PATCH_REGEX"; then
    emit_ok "fork patches detected in git log"
  else
    emit_warn "fork patches not detected in last 20 commits — build may fail on macOS Tahoe / GDAL 3.12 / SpatiaLite 5. See README."
  fi
else
  emit_fail "$PROCESS_FAA_DATA_DIR is not a git clone — run scripts/setup.sh --clone-build-tool"
fi

section "Built data ($NASR_DATA_DIR)"
if [ -d "$NASR_DATA_DIR" ]; then
  emit_ok "data dir exists"
  expected=(
    nasr.sqlite
    spatialite_nasr.sqlite
    controlled_airspace_spatialite.sqlite
    special_use_airspace_spatialite.sqlite
    class_airspace.parquet
    special_use_airspace.parquet
    obstacle.parquet
  )
  missing=0
  for f in "${expected[@]}"; do
    if [ ! -f "$NASR_DATA_DIR/$f" ]; then
      emit_fail "missing $f"
      missing=$((missing + 1))
    fi
  done
  [ "$missing" = 0 ] && emit_ok "all expected sqlite + parquet files present"

  if [ -f "$NASR_DATA_DIR/CYCLE.txt" ]; then
    cycle=$(cat "$NASR_DATA_DIR/CYCLE.txt" | tr -d '[:space:]')
    if date -j -f "%Y-%m-%d" "$cycle" "+%s" >/dev/null 2>&1; then
      cycle_epoch=$(date -j -f "%Y-%m-%d" "$cycle" "+%s")
    else
      cycle_epoch=$(date -d "$cycle" "+%s" 2>/dev/null || echo "")
    fi
    if [ -n "$cycle_epoch" ]; then
      now_epoch=$(date "+%s")
      age_days=$(( (now_epoch - cycle_epoch) / 86400 ))
      if [ "$age_days" -le 28 ]; then
        emit_ok "cycle $cycle is $age_days days old (current)"
      elif [ "$age_days" -le 56 ]; then
        emit_warn "cycle $cycle is $age_days days old (1 cycle behind) — refresh recommended"
      else
        emit_warn "cycle $cycle is $age_days days old (>=2 cycles behind) — refresh strongly recommended"
      fi
    else
      emit_warn "could not parse CYCLE.txt contents: $cycle"
    fi
  else
    emit_warn "no CYCLE.txt — run scripts/refresh.sh"
  fi
else
  emit_fail "$NASR_DATA_DIR does not exist — run scripts/setup.sh --build (or --all)"
fi

if [ -n "${ADSB_PARQUET_DIR:-}" ]; then
  section "ADS-B archive (optional)"
  if [ -d "$ADSB_PARQUET_DIR" ]; then
    first=$(find "$ADSB_PARQUET_DIR" -maxdepth 2 -name '*.parquet' -print -quit 2>/dev/null)
    if [ -n "$first" ]; then
      emit_ok "ADS-B parquet files present in $ADSB_PARQUET_DIR"
    else
      emit_warn "ADSB_PARQUET_DIR set but no .parquet files found"
    fi
  else
    emit_warn "ADSB_PARQUET_DIR set but directory does not exist"
  fi
fi

section "Summary"
if [ ${#PROBLEMS[@]} -eq 0 ]; then
  printf "OK — no critical problems"
  [ ${#WARNINGS[@]} -gt 0 ] && printf " (%d warning(s))" ${#WARNINGS[@]}
  printf "\n"
  exit 0
else
  printf "FAILED — %d critical problem(s), %d warning(s)\n" \
    ${#PROBLEMS[@]} ${#WARNINGS[@]}
  exit 1
fi
