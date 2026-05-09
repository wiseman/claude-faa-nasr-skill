# claude-faa-nasr-skill

An [agent skill](https://agentskills.io) for querying the FAA's NASR
(National Airspace System Resources) 28-day subscription data. Once
installed, the agent can:

- Look up airports, runways, navaids, fixes, airways, ILS, ATC
  frequencies, obstacles
- Query Class B/C/D/E airspace geometry and floors/ceilings
- Query special-use airspace (Restricted, Prohibited, MOA, Warning,
  Alert) including AIXM composition trees
- Refresh the local databases from the latest FAA cycle
- Optionally join NASR polygons against an external ADS-B parquet
  archive for traffic-vs-airspace analyses

The skill is reference material only — it doesn't ship the data. You
build the four SQLite/SpatiaLite databases locally from the FAA's free
NASR subscription using [jlmcgraw/processFaaData][upstream], then
generate three GeoParquet sidecars with `ogr2ogr`.

[upstream]: https://github.com/jlmcgraw/processFaaData

## Quick start

Supported platforms: macOS (Apple Silicon or Intel), Debian/Ubuntu, WSL.

```bash
git clone https://github.com/wiseman/claude-faa-nasr-skill ~/code/claude-faa-nasr-skill
cd ~/code/claude-faa-nasr-skill

# install prereqs, clone build tool, install Perl deps, run first build, run doctor
./scripts/setup.sh --all
```

Then symlink the skill into whichever agent you use:

```bash
# Claude Code
mkdir -p ~/.claude/skills
ln -s ~/code/claude-faa-nasr-skill ~/.claude/skills/faa-nasr

# OpenAI Codex CLI
mkdir -p ~/.agents/skills
ln -s ~/code/claude-faa-nasr-skill ~/.agents/skills/faa-nasr
```

`./scripts/setup.sh --all` is idempotent. Run `./scripts/setup.sh
--help` for individual phases if you need to re-run just one.

To rebuild later cycles (FAA publishes a new one every 28 days):

```bash
./scripts/refresh.sh
```

## Prerequisites

`./scripts/setup.sh` installs everything below. This table is
the fallback for unsupported platforms or when you'd rather install by
hand.

| Tool                          | Purpose                                                                           | macOS (Homebrew)                                    | Debian/Ubuntu/WSL                                                                         |
| ----------------------------- | --------------------------------------------------------------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Perl 5.34+ + cpanm            | NASR-to-SQLite converter                                                          | `brew install perl cpanminus`                       | `sudo apt install perl cpanminus`                                                         |
| sqlite3 with `load_extension` | Apple's stock build omits it                                                      | `brew install sqlite`                               | `sudo apt install sqlite3` (already supports load_extension)                              |
| libspatialite + tools         | SQLite spatial extensions                                                         | `brew install libspatialite spatialite-tools`       | `sudo apt install libsqlite3-mod-spatialite spatialite-bin`                               |
| GDAL                          | `ogr2ogr` for spatial conversions                                                 | `brew install gdal` (ships with the Parquet driver) | `sudo apt install gdal-bin python3-gdal` (apt build lacks the Parquet driver — see below) |
| `uv`                          | Required on Linux only, runs the Python GeoParquet fallback for the sidecar build | not needed on macOS (Homebrew GDAL handles Parquet) | `wget -qO- https://astral.sh/uv/install.sh \| sh`                                         |
| DuckDB with spatial + parquet | Cross-format queries                                                              | `brew install duckdb`                               | Install from <https://duckdb.org> (apt lags; setup.sh fetches the official binary)        |
| `wget`                        | Download FAA subscription                                                         | `brew install wget`                                 | `sudo apt install wget`                                                                   |

**Note on GDAL+Parquet on Linux/WSL:** Ubuntu 24.04's stock `gdal-bin`
does not include the Parquet driver. `scripts/refresh.sh` detects this
and falls back to `scripts/build-parquet-sidecars.py`, which uses
`pyogrio` (bundles its own GDAL with Parquet support) under `uv`.
`setup.sh` installs `uv` automatically on Linux.

For details, including the full manual build recipe, see
[`references/manual-build.md`](references/manual-build.md).

### processFaaData — fork or upstream?

The upstream repo is somewhat dormant and has bugs that prevent the
build from succeeding on macOS Tahoe / GDAL 3.12 / SpatiaLite 5. Until
[jlmcgraw/processFaaData#17](https://github.com/jlmcgraw/processFaaData/pull/17)
merges, the build needs the patched fork at
<https://github.com/wiseman/processFaaData>. `setup.sh` clones the fork on the right branch
automatically; if you already have an upstream clone, it adds the
fork as a remote and fast-forward-merges the patches.

## Configuration

The skill reads paths from environment variables, with defaults that
match the layout `setup.sh` produces. Override any of them in your
shell, in `./config.sh`, or in
`~/.config/faa-nasr-skill/config.sh`. Discovery order (first hit
wins):

1. Existing environment variable
2. `$FAA_NASR_CONFIG` (if set, treated as a path to a config file)
3. `./config.sh` next to the skill
4. `${XDG_CONFIG_HOME:-~/.config}/faa-nasr-skill/config.sh`
5. Built-in defaults

| Variable               | Default                | What                                                                      |
| ---------------------- | ---------------------- | ------------------------------------------------------------------------- |
| `NASR_DATA_DIR`        | `~/data/faa/nasr`      | Where built sqlite + parquet + `CYCLE.txt` live                           |
| `PROCESS_FAA_DATA_DIR` | `~/src/processFaaData` | Clone of the build tool                                                   |
| `ADSB_PARQUET_DIR`     | (unset)                | Optional. Set if you have an ADS-B parquet archive for cross-format joins |
| `SQLITE_BIN`           | auto-detected          | sqlite3 binary supporting `.load mod_spatialite`                          |
| `MOD_SPATIALITE_PATH`  | auto-detected          | Full path to the SpatiaLite shared library                                |

To populate the variables in your shell:

```bash
source ./scripts/load-config.sh
```

Or just inspect what the skill resolves to:

```bash
./scripts/doctor.sh --paths
```

A template is provided at `config.sh.example` — copy it to `config.sh`
and uncomment the variables you want to override.

## What's in the skill

```
SKILL.md                       # entry point: data layout, decision tree, gotchas
references/schema.md           # ~70 NASR table reference + AIXM SUA schema
references/cookbook.md         # query recipes + 10 worked challenges
references/refresh.md          # cycle refresh procedure + troubleshooting
references/manual-build.md     # by-hand build recipe (if you'd rather not run setup.sh)
scripts/setup.sh               # one-shot installer
scripts/refresh.sh             # 28-day cycle refresh
scripts/doctor.sh              # health check / path inspector
scripts/load-config.sh         # source this to populate env vars
config.sh.example              # template config file
```

After install, ask the agent things like:

- "How many distinct ATC frequencies are within 25 NM of LAX?"
- "Which airports above 6,000 ft elevation have an ILS approach?"
- "What's the floor/ceiling structure of the SAN FRANCISCO Class B?"
- "Find tallest obstacles within 5 NM of the great-circle route from
  KSFO to KJFK."
- "Refresh the NASR databases."

## License

MIT. The FAA NASR data itself is in the public domain.

## Credits

- [jlmcgraw/processFaaData][upstream] — the Perl converter that does
  the actual NASR-text → SQLite work
- The FAA's [NFDC NASR Subscription][faa] feed
- This skill is just thoughtful glue around those.

[faa]: https://www.faa.gov/air_traffic/flight_info/aeronav/aero_data/NASR_Subscription/
