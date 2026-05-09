#!/usr/bin/env bash
# scripts/setup.sh — install prereqs + clone build tool + first build.
#
# Phases (combine as needed):
#   --prereqs            install OS packages via brew/apt
#   --clone-build-tool   clone wiseman/processFaaData into $PROCESS_FAA_DATA_DIR
#   --perl-deps          install Perl deps via cpanm into $PROCESS_FAA_DATA_DIR/local
#   --build              fetch + build the current NASR cycle (calls refresh.sh)
#   --doctor             run scripts/doctor.sh and exit
#   --all                run all phases above, in order
#
# Anything not idempotent is guarded — re-running is safe.
#
# Supported platforms: macOS arm64, macOS x86_64, Debian/Ubuntu (incl. WSL).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=load-config.sh
. "$SCRIPT_DIR/load-config.sh"

FORK_REPO="https://github.com/wiseman/processFaaData"
FORK_BRANCH="macos-tahoe-upstream-fixes"

DO_PREREQS=0
DO_CLONE=0
DO_PERL=0
DO_BUILD=0
DO_DOCTOR=0

if [ $# -eq 0 ]; then
  echo "setup.sh: pass at least one of --prereqs --clone-build-tool --perl-deps --build --all --doctor" >&2
  exit 2
fi

for arg in "$@"; do
  case "$arg" in
    --prereqs) DO_PREREQS=1 ;;
    --clone-build-tool) DO_CLONE=1 ;;
    --perl-deps) DO_PERL=1 ;;
    --build) DO_BUILD=1 ;;
    --doctor) DO_DOCTOR=1 ;;
    --all)
      DO_PREREQS=1; DO_CLONE=1; DO_PERL=1; DO_BUILD=1; DO_DOCTOR=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "setup.sh: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

# ---------- platform detection ----------

detect_platform() {
  case "$(uname -s)" in
    Darwin)
      case "$(uname -m)" in
        arm64) echo "macos-arm64" ;;
        x86_64) echo "macos-x86_64" ;;
        *) echo "macos-unknown" ;;
      esac
      ;;
    Linux)
      if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}${ID_LIKE:-}" in
          *debian*|*ubuntu*) echo "linux-debian"; return ;;
        esac
      fi
      echo "linux-unknown"
      ;;
    *) echo "unknown" ;;
  esac
}

PLATFORM=$(detect_platform)
echo "==> Detected platform: $PLATFORM"

case "$PLATFORM" in
  macos-arm64|macos-x86_64|linux-debian) ;;
  *)
    echo "setup.sh: platform '$PLATFORM' is not supported by --prereqs." >&2
    echo "Install prerequisites manually (see README.md) and re-run with the other phases." >&2
    [ "$DO_PREREQS" = 1 ] && exit 1
    ;;
esac

# ---------- helpers ----------

confirm() {
  # Non-interactive shells: assume yes.
  if [ ! -t 0 ]; then return 0; fi
  read -r -p "$1 [Y/n] " ans
  case "$ans" in
    n|N|no|NO) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------- prereqs ----------

install_prereqs_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required. Install from https://brew.sh and re-run." >&2
    exit 1
  fi
  local pkgs=(perl cpanminus sqlite libspatialite spatialite-tools gdal duckdb wget)
  echo "==> The following Homebrew packages will be installed (already-installed are no-ops):"
  printf '       %s\n' "${pkgs[@]}"
  confirm "Proceed?" || { echo "Aborted."; exit 1; }
  brew install "${pkgs[@]}"
}

install_prereqs_debian() {
  local apt_pkgs=(git perl cpanminus sqlite3 libsqlite3-mod-spatialite spatialite-bin gdal-bin python3-gdal wget unzip ca-certificates)
  # Note: Ubuntu/Debian gdal-bin lacks the Parquet driver. We install
  # uv below so refresh.sh can use scripts/build-parquet-sidecars.py
  # as a fallback.
  # Use sudo only if we're not already root (e.g. inside a container).
  local sudo_cmd=""
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo_cmd="sudo"
    else
      echo "setup.sh: not root and 'sudo' is not installed — install sudo or run as root." >&2
      exit 1
    fi
  fi
  echo "==> The following apt packages will be installed via '${sudo_cmd:+$sudo_cmd }apt-get install':"
  printf '       %s\n' "${apt_pkgs[@]}"
  confirm "Proceed?" || { echo "Aborted."; exit 1; }
  $sudo_cmd apt-get update
  DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y "${apt_pkgs[@]}"

  if ! command -v duckdb >/dev/null 2>&1; then
    echo "==> apt does not ship a recent DuckDB; installing the official binary into /usr/local/bin"
    if confirm "Download and install DuckDB from duckdb.org?"; then
      local arch="" tarname tmp
      case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) echo "Unsupported arch for DuckDB autoinstall." ;;
      esac
      if [ -n "$arch" ]; then
        tarname="duckdb_cli-linux-${arch}.zip"
        tmp=$(mktemp -d)
        (cd "$tmp" && wget -q "https://github.com/duckdb/duckdb/releases/latest/download/$tarname" \
           && unzip -q "$tarname")
        $sudo_cmd install -m 0755 "$tmp/duckdb" /usr/local/bin/duckdb
        rm -rf "$tmp"
      fi
    else
      echo "Skipping DuckDB. Install it manually before running cross-format queries."
    fi
  fi

  # uv is needed because Ubuntu's gdal-bin lacks the Parquet driver,
  # so refresh.sh falls back to a uv-run Python helper for the
  # GeoParquet sidecars (see scripts/build-parquet-sidecars.py).
  if ! command -v uv >/dev/null 2>&1; then
    echo "==> Installing uv (required for the GeoParquet sidecar build on Linux)"
    if confirm "Install uv via the official installer at https://astral.sh/uv/install.sh?"; then
      wget -qO- https://astral.sh/uv/install.sh | sh
      # uv lands in ~/.local/bin; make sure subsequent commands find it.
      export PATH="$HOME/.local/bin:$PATH"
    else
      echo "Skipping uv. refresh.sh will fail at the sidecar step until uv is installed."
    fi
  fi
}

if [ "$DO_PREREQS" = 1 ]; then
  case "$PLATFORM" in
    macos-arm64|macos-x86_64) install_prereqs_macos ;;
    linux-debian) install_prereqs_debian ;;
  esac
fi

# ---------- clone build tool ----------

if [ "$DO_CLONE" = 1 ]; then
  if [ -d "$PROCESS_FAA_DATA_DIR/.git" ]; then
    echo "==> processFaaData clone already at $PROCESS_FAA_DATA_DIR — skipping clone"
    # Make sure the patches are present.
    log=$(cd "$PROCESS_FAA_DATA_DIR" && git log --oneline -20 2>/dev/null || true)
    if echo "$log" | grep -qiE "$FAA_NASR_FORK_PATCH_REGEX"; then
      echo "    fork patches detected"
    else
      echo "    fork patches not detected — adding fork remote and merging"
      (
        cd "$PROCESS_FAA_DATA_DIR"
        if ! git remote | grep -qx fork; then
          git remote add fork "$FORK_REPO.git"
        fi
        git fetch fork
        git merge --ff-only "fork/$FORK_BRANCH"
      )
    fi
  else
    echo "==> Cloning $FORK_REPO into $PROCESS_FAA_DATA_DIR"
    mkdir -p "$(dirname "$PROCESS_FAA_DATA_DIR")"
    git clone "$FORK_REPO" "$PROCESS_FAA_DATA_DIR"
    # Switch to fork branch if it isn't the default.
    (
      cd "$PROCESS_FAA_DATA_DIR"
      if git show-ref --quiet "refs/heads/$FORK_BRANCH"; then
        git checkout "$FORK_BRANCH"
      elif git show-ref --quiet "refs/remotes/origin/$FORK_BRANCH"; then
        git checkout -b "$FORK_BRANCH" "origin/$FORK_BRANCH"
      fi
    )
  fi
fi

# ---------- perl deps ----------

if [ "$DO_PERL" = 1 ]; then
  if [ ! -d "$PROCESS_FAA_DATA_DIR" ]; then
    echo "setup.sh: $PROCESS_FAA_DATA_DIR not present — run --clone-build-tool first." >&2
    exit 1
  fi
  if ! command -v cpanm >/dev/null 2>&1; then
    echo "setup.sh: cpanm not on PATH — run --prereqs first." >&2
    exit 1
  fi
  echo "==> Installing Perl deps into $PROCESS_FAA_DATA_DIR/local"
  (cd "$PROCESS_FAA_DATA_DIR" && cpanm -L local --installdeps --notest .)
fi

# ---------- build ----------

if [ "$DO_BUILD" = 1 ]; then
  echo "==> Running first-time build via scripts/refresh.sh"
  "$SCRIPT_DIR/refresh.sh"
fi

# ---------- doctor ----------

if [ "$DO_DOCTOR" = 1 ]; then
  echo "==> Final health check"
  "$SCRIPT_DIR/doctor.sh"
fi

echo "==> setup.sh done"
