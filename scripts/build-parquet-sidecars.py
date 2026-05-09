#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "pyogrio>=0.10",
#     "pyarrow>=16",
# ]
# ///
"""Convert the three SpatiaLite tables we sidecar to GeoParquet.

Fallback for systems whose `ogr2ogr` lacks the Parquet driver
(canonically Ubuntu 24.04's apt gdal-bin). pyogrio bundles its own
GDAL with the SpatiaLite reader, so we only need uv to bootstrap.

We deliberately use pyogrio.raw.read_arrow rather than the geopandas
path: a handful of SUA polygons in NASR have non-closed rings (see
SKILL.md), and shapely.from_wkb refuses to parse them. The raw-Arrow
path keeps the WKB blobs untouched — exactly what ogr2ogr does — and
we attach a minimal GeoParquet `geo` metadata block so DuckDB-spatial
recognizes the geometry column. Downstream queries still need
ST_MakeValid for the broken rings, same as with the ogr2ogr output.

Usage:
    build-parquet-sidecars.py <NASR_DATA_DIR>
"""
import json
import os
import sys
import time
import warnings

import pyarrow as pa
import pyarrow.parquet as pq
import pyogrio


LAYERS = [
    # (output parquet, input sqlite, layer name, geometry column name or None)
    # OBSTACLE_OBSTACLE has obstacle_latitude / obstacle_longitude as
    # plain doubles plus a SpatiaLite blob `obstacleGeom`. ogr2ogr's
    # sidecar drops the blob (cookbook recipes use the doubles
    # directly), so we match that here by passing geom_col=None.
    ("class_airspace.parquet",       "controlled_airspace_spatialite.sqlite",  "Class_Airspace",    "GEOMETRY"),
    ("special_use_airspace.parquet", "special_use_airspace_spatialite.sqlite", "Airspace",          "GEOMETRY"),
    ("obstacle.parquet",             "spatialite_nasr.sqlite",                 "OBSTACLE_OBSTACLE", None),
]


def attach_geo_metadata(table: pa.Table, geom_col: str) -> pa.Table:
    """Add a GeoParquet 1.1 `geo` metadata block to the table.

    This is the minimum that DuckDB-spatial and other GeoParquet
    readers need to recognize the WKB column as geometry. We omit
    `bbox` and `geometry_types` (would require parsing every WKB) —
    consumers fall back to scanning the data, which is what they'd
    do anyway for downstream filtering.
    """
    geo = {
        "version": "1.1.0",
        "primary_column": geom_col,
        "columns": {
            geom_col: {
                "encoding": "WKB",
                "geometry_types": [],
            }
        },
    }
    existing = table.schema.metadata or {}
    new_meta = {**existing, b"geo": json.dumps(geo).encode("utf-8")}
    return table.replace_schema_metadata(new_meta)


def convert(in_path: str, layer: str, geom_col: str | None, out_path: str) -> int:
    # GDAL's "non closed ring" check warns on read; suppress it — we
    # propagate the broken WKB to parquet faithfully, same as ogr2ogr.
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", category=RuntimeWarning)
        _, table = pyogrio.raw.read_arrow(in_path, layer=layer)
    if geom_col is None:
        # No geometry: drop any SpatiaLite blob columns so the output
        # matches ogr2ogr's lat/lon-only sidecar shape.
        drop = [
            n for n, t in zip(table.schema.names, table.schema.types)
            if pa.types.is_binary(t) or pa.types.is_large_binary(t)
        ]
        if drop:
            table = table.drop(drop)
    else:
        if geom_col not in table.schema.names:
            cands = [n for n in table.schema.names if n.lower() == geom_col.lower()]
            if not cands:
                raise RuntimeError(
                    f"no geometry column matching {geom_col!r} in {in_path}::{layer}; "
                    f"have: {table.schema.names}"
                )
            if len(cands) > 1:
                raise RuntimeError(
                    f"ambiguous geometry column for {geom_col!r} in {in_path}::{layer}: {cands}"
                )
            idx = table.schema.get_field_index(cands[0])
            table = table.rename_columns(
                [geom_col if i == idx else n for i, n in enumerate(table.schema.names)]
            )
        table = attach_geo_metadata(table, geom_col)
    pq.write_table(table, out_path)
    return table.num_rows


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <NASR_DATA_DIR>", file=sys.stderr)
        return 2
    nasr_dir = sys.argv[1]
    if not os.path.isdir(nasr_dir):
        print(f"error: {nasr_dir} is not a directory", file=sys.stderr)
        return 1

    for out_name, in_name, layer, geom_col in LAYERS:
        in_path = os.path.join(nasr_dir, in_name)
        out_path = os.path.join(nasr_dir, out_name)
        if not os.path.isfile(in_path):
            print(f"error: missing {in_path}", file=sys.stderr)
            return 1
        t0 = time.time()
        n = convert(in_path, layer, geom_col, out_path)
        size_mb = os.path.getsize(out_path) / 1e6
        print(f"  {out_name}: {n:,} rows, {size_mb:.1f} MB ({time.time() - t0:.1f}s)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
