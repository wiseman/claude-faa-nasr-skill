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

The `setup.sh` step below will download the latest NASR dataset and
build the databases automatically. This uses about 250 MB of disk space
and takes a few minutes to run.

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

Then use the skill:

```
$ claude
❯ Create an ASCII histogram of runway lengths in the U.S.

⏺ Skill(faa-nasr)
  ⎿  Successfully loaded skill

⏺ U.S. runway lengths (n=23,221, FAA NASR cycle 2026-04-16)

     length (ft)  count          %
  --------------------------------------------------------------------------------
           0-999  6,650  ################################################## 28.6%
     1,000-1,999  3,157  ######################## 13.6%
     2,000-2,999  5,350  ######################################## 23.0%
     3,000-3,999  3,037  ####################### 13.1%
     4,000-4,999  1,709  ############# 7.4%
     5,000-5,999  1,561  ############ 6.7%
     6,000-6,999    610  ##### 2.6%
     7,000-7,999    327  ## 1.4%
     8,000-8,999    263  ## 1.1%
     9,000-9,999    152  # 0.7%
   10,000-10,999    196  # 0.8%
   11,000-11,999     73  # 0.3%
   12,000-12,999     65   0.3%
   13,000-13,999     31   0.1%
   14,000-14,999      7   0.0%
         15,000+     33   0.1%

  Notes:

  - Source: APT_RWY.runway_physical_runway_length_nearest_foot, all 50
    states + DC + U.S. territories (PR, GU, VI, AS, MP, Wake, Midway,
    Palmyra). 1,000-ft bins.

  - The 0-999 / 2-3k spikes are dominated by seaplane water lanes,
    helipads-marked-as-runways, and short turf strips — many "runways"
    in NASR aren't paved.

  - 15,000+ bin is mostly seaplane lanes on big lakes; the longest
    paved runways are DEN 16R/34L, EDW, VBG, and KSC's shuttle landing
    facility (all ~15-16k ft).

❯ how many different tower frequencies does LAX have?

⏺ LAX has 5 distinct tower (local control) frequencies in NASR — 3 VHF
  and 2 UHF military duplicates:

  ┌───────────────────┬──────────────────────────────────┐
  │       Freq        │              Sector              │
  ├───────────────────┼──────────────────────────────────┤
  │ 119.800 MHz       │ Helicopters                      │
  ├───────────────────┼──────────────────────────────────┤
  │ 120.950 MHz       │ South Complex (rwys 25L/R, 7L/R) │
  ├───────────────────┼──────────────────────────────────┤
  │ 133.900 MHz       │ North Complex (rwys 24L/R, 6L/R) │
  ├───────────────────┼──────────────────────────────────┤
  │ 239.300 MHz (UHF) │ North Complex & helicopters      │
  ├───────────────────┼──────────────────────────────────┤
  │ 379.100 MHz (UHF) │ South Complex                    │
  └───────────────────┴──────────────────────────────────┘

  If you mean "all frequencies at the LAX tower facility" (i.e.
  everything in TWR_TWR3, including ground, clearance delivery,
  D-ATIS, ramp control, emergency, ops), it's 22 distinct frequencies
  across 3 record rows: tower x5, ground x4 (121.4 / 121.65 / 121.75 /
  327.0 UHF), clearance delivery x2 (120.35 / 327.0 — same UHF as
  ground), D-ATIS x2 (133.80 arr / 135.65 dep), 5 ramp control freqs
  (129.4, 129.5, 130.5, 130.85, 131.45), SFRA 128.55, emergency
  121.5/243.0, and ops 372.2.

  Source: TWR_TWR3 rows where master_record_row_id=484 (LAX).

❯ What are VNY's ILS approaches?

⏺ VNY has one ILS approach: ILS Rwy 16R.

  ┌─────────────────┬────────────────────────────────────────────┐
  │      Field      │                   Value                    │
  ├─────────────────┼────────────────────────────────────────────┤
  │ Type / Cat      │ ILS, Cat I                                 │
  ├─────────────────┼────────────────────────────────────────────┤
  │ Ident           │ I-VNY                                      │
  ├─────────────────┼────────────────────────────────────────────┤
  │ Localizer freq  │ 111.3 MHz (status: OPERATIONAL RESTRICTED) │
  ├─────────────────┼────────────────────────────────────────────┤
  │ Glideslope      │ 332.3 MHz, 3.5° angle (OPERATIONAL IFR)    │
  ├─────────────────┼────────────────────────────────────────────┤
  │ Approach course │ 163.51° magnetic                           │
  ├─────────────────┼────────────────────────────────────────────┤
  │ Outer marker    │ KADIE (decommissioned, 2016-06-14)         │
  ├─────────────────┼────────────────────────────────────────────┤
  │ Middle marker   │ decommissioned 2015-11-13                  │
  └─────────────────┴────────────────────────────────────────────┘

  Notable remarks from ILS_ILS6:
  - ILS unmonitored when ATCT closed
  - ILS classification code IA
  - LOC unusable within 0.6 NM
  - Autopilot-coupled approach NA below 1509 ft MSL

  That's the only ILS in NASR for VNY. Other published approaches at
  VNY (RNAV/GPS, VOR, LOC-only variants on 16R) live in CIFP/d-TPP and
  aren't in this database.
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
