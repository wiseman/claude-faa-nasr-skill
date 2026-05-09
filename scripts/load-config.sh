# shellcheck shell=bash
# scripts/load-config.sh
#
# Source this file from other scripts (or your shell) to populate the
# faa-nasr-skill environment variables. Safe to source multiple times.
#
#   source scripts/load-config.sh
#
# After sourcing, these variables are guaranteed to be set:
#
#   NASR_DATA_DIR
#   PROCESS_FAA_DATA_DIR
#   SQLITE_BIN
#   MOD_SPATIALITE_PATH
#
# And ADSB_PARQUET_DIR is set iff the user opted in (existing env or
# config-file value); it's deliberately left unset otherwise so
# downstream code can branch on `[ -n "${ADSB_PARQUET_DIR:-}" ]`.

_faa_nasr_skill_dir() {
  # Directory containing this script's parent (i.e. the skill root).
  local self="${BASH_SOURCE[0]:-$0}"
  cd "$(dirname "$self")/.." && pwd
}

_faa_nasr_load_file() {
  local f=$1
  if [ -f "$f" ]; then
    # shellcheck disable=SC1090
    . "$f"
  fi
}

_faa_nasr_skill_root=$(_faa_nasr_skill_dir)

# 1. Explicit FAA_NASR_CONFIG path wins over discovery.
if [ -n "${FAA_NASR_CONFIG:-}" ]; then
  _faa_nasr_load_file "$FAA_NASR_CONFIG"
fi

# 2. ./config.sh next to the skill.
_faa_nasr_load_file "$_faa_nasr_skill_root/config.sh"

# 3. XDG config dir.
_faa_nasr_xdg=${XDG_CONFIG_HOME:-$HOME/.config}
_faa_nasr_load_file "$_faa_nasr_xdg/faa-nasr-skill/config.sh"

# 4. Defaults for anything still unset.
: "${NASR_DATA_DIR:=$HOME/data/faa/nasr}"
: "${PROCESS_FAA_DATA_DIR:=$HOME/src/processFaaData}"

# Auto-detect SQLITE_BIN if not pinned. A sqlite that supports `.load`
# returns a dlopen-style error for a bogus path; Apple's stock build
# (SQLITE_OMIT_LOAD_EXTENSION) says "not authorized" instead.
if [ -z "${SQLITE_BIN:-}" ]; then
  for _c in "/opt/homebrew/opt/sqlite/bin/sqlite3" \
            "/usr/local/opt/sqlite/bin/sqlite3" \
            "sqlite3"; do
    _bin=$(command -v "$_c" 2>/dev/null || true)
    [ -n "$_bin" ] || continue
    _err=$("$_bin" :memory: ".load this_path_does_not_exist_xyz" 2>&1 || true)
    case "$_err" in
      *"not authorized"*|*"omitted"*) continue ;;
    esac
    SQLITE_BIN=$_bin
    break
  done
  unset _c _bin _err
fi
: "${SQLITE_BIN:=sqlite3}"

# Auto-detect MOD_SPATIALITE_PATH if not pinned. On Linux the bare
# name resolves via the loader's search path.
if [ -z "${MOD_SPATIALITE_PATH:-}" ]; then
  for _c in "/opt/homebrew/lib/mod_spatialite.dylib" \
            "/usr/local/lib/mod_spatialite.dylib" \
            "/opt/homebrew/lib/mod_spatialite" \
            "/usr/local/lib/mod_spatialite" \
            "/usr/lib/x86_64-linux-gnu/mod_spatialite.so" \
            "/usr/lib/aarch64-linux-gnu/mod_spatialite.so" \
            "/usr/lib/mod_spatialite.so"; do
    if [ -e "$_c" ]; then
      MOD_SPATIALITE_PATH=$_c
      break
    fi
  done
  if [ -z "${MOD_SPATIALITE_PATH:-}" ] && [ "$(uname -s)" = "Linux" ]; then
    MOD_SPATIALITE_PATH=mod_spatialite
  fi
  unset _c
fi
: "${MOD_SPATIALITE_PATH:=mod_spatialite}"

# Regex matching the fork-patch commit subjects from
# wiseman/processFaaData. Used by setup.sh and doctor.sh.
FAA_NASR_FORK_PATCH_REGEX="spatialite ?5|trusted_schema|gdal 3\.12|macos.*portab"

export NASR_DATA_DIR PROCESS_FAA_DATA_DIR SQLITE_BIN MOD_SPATIALITE_PATH FAA_NASR_FORK_PATCH_REGEX
[ -n "${ADSB_PARQUET_DIR:-}" ] && export ADSB_PARQUET_DIR

unset _faa_nasr_skill_root _faa_nasr_xdg
unset -f _faa_nasr_skill_dir _faa_nasr_load_file
