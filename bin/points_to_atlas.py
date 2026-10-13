#!/usr/bin/env python3
"""Transform spotiflow detections into atlas space with one registration and summarise per region.

    points_to_atlas.py --detections <det_dir>/ch1.csv --registration <variant dir> \
        --zarr <brain>/ch1.ome.zarr --out <dir> [--evaluation registration_qc/evaluation.json]

Pipeline port of ~/scripts/data_transfer/points_to_atlas_optimal.py. The
differences are only where the inputs come from:
  * full-res (z, y, x) shape: level 0 of the OME-Zarr spotiflow ran on (instead
    of the fused C1 tiff header over SSH);
  * voxel sizes (z, y, x), raw orientation and atlas: the registration's own
    brainreg.json (instead of mouse_info.csv), so they cannot disagree with the
    registration the points are pushed through.

ch1.csv columns are z, y, x, so points, shape and voxel sizes are all (z, y, x).

Writes to --out: downsampled.points, atlas.points, all_points.csv, summary.csv and
registration_choice.json (which variant was used and how good it is).
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import brainglobe_space as bgs
import numpy as np
import pandas as pd
import tifffile
from brainglobe_atlasapi import BrainGlobeAtlas
from brainglobe_utils.brainmapper.analysis import summarise_points_by_atlas_region

DOWNSAMPLED_ORIENTATION = "asr"  # atlas orientation of the downsampled image


def zarr_shape(zarr: Path) -> tuple[int, int, int]:
    """(z, y, x) of the full-resolution level of an OME-Zarr (v2 or v3).

    `zarr` is the .ome.zarr folder or directly its level-0 metadata file
    (0/.zarray or 0/zarr.json).
    """
    candidates = [zarr] if zarr.is_file() else [zarr / "0" / ".zarray", zarr / "0" / "zarr.json"]
    for meta in candidates:
        if meta.exists():
            shape = json.loads(meta.read_text())["shape"]
            return tuple(int(s) for s in shape[-3:])
    raise FileNotFoundError(f"no level-0 array metadata in {zarr}")


def downsampled_registration_channel(reg_dir: Path) -> Path:
    """The unwarped downsampled registration channel (C0), not the standard-space one."""
    candidates = sorted(p for p in reg_dir.glob("downsampled_*_C0.tif*")
                        if not p.name.startswith("downsampled_standard"))
    if not candidates and (reg_dir / "downsampled.tiff").exists():
        candidates = [reg_dir / "downsampled.tiff"]
    if not candidates:
        raise FileNotFoundError(f"no downsampled_*_C0.tiff in {reg_dir}")
    if len(candidates) > 1:
        print(f"WARNING: multiple downsampled C0 images, using {candidates[0].name}")
    return candidates[0]


def downsampled_points_to_atlas_fast(downsampled_points, atlas, deformation_field_paths,
                                     output_filename=None):
    """Vectorized drop-in for brainglobe_utils'
    transform_points_from_downsampled_to_atlas_space.

    The library applies the three deformation fields with a per-point Python
    loop; this does the identical computation with array ops: round with np.rint
    (== Python round), drop points that would raise IndexError on any field
    (indices in [-dim, 0) wrap like numpy and are kept), gather field[z, y, x]
    and scale by int(1000 / res). Returns the in-bounds atlas-space points in
    the original order, as the library's first return value.
    """
    field_scales = [int(1000 / r) for r in atlas.resolution]
    pts = np.rint(np.asarray(downsampled_points, dtype=float)).astype(np.int64)

    in_bounds = np.ones(len(pts), dtype=bool)
    for path in deformation_field_paths:
        with tifffile.TiffFile(path) as tif:
            shape = tif.series[0].shape
        for axis in range(3):
            idx = pts[:, axis]
            in_bounds &= (idx >= -shape[axis]) & (idx < shape[axis])

    valid = pts[in_bounds]
    transformed = np.empty((valid.shape[0], 3), dtype=np.int64)
    for axis, path in enumerate(deformation_field_paths):
        field = tifffile.imread(path)
        vals = field[valid[:, 0], valid[:, 1], valid[:, 2]]
        # float64 to match the library's scalar float32 * int promotion
        transformed[:, axis] = np.rint(
            field_scales[axis] * vals.astype(np.float64)).astype(np.int64)
        del field

    if output_filename is not None:
        pd.DataFrame(transformed).to_hdf(output_filename, key="df", mode="w")
    return transformed, int((~in_bounds).sum())


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--detections", required=True, type=Path, help="spotiflow ch1.csv (z,y,x)")
    parser.add_argument("--registration", required=True, type=Path,
                        help="the chosen brainreg output folder")
    parser.add_argument("--registration-name", default=None,
                        help="name of the chosen variant (as published), for the record")
    parser.add_argument("--zarr", required=True, type=Path, help="ch1.ome.zarr spotiflow ran on, or its 0/.zarray")
    parser.add_argument("--evaluation", type=Path, default=None,
                        help="registration_qc/evaluation.json, copied into registration_choice.json")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    reg = args.registration
    brainreg = json.loads((reg / "brainreg.json").read_text())
    voxel_sizes = [float(v) for v in brainreg["voxel_sizes"]]       # z, y, x
    raw_orientation = brainreg["orientation"]
    atlas = BrainGlobeAtlas(brainreg["atlas"])
    deformation_fields = [reg / f"deformation_field_{i}.tiff" for i in range(3)]
    missing = [str(p) for p in deformation_fields if not p.exists()]
    if missing:
        raise SystemExit(f"missing deformation fields: {missing}")

    cells = pd.read_csv(args.detections)[["z", "y", "x"]].to_numpy(dtype=float)
    if not len(cells):
        raise SystemExit(f"no detections in {args.detections}")
    full_shape = zarr_shape(args.zarr)
    with tifffile.TiffFile(downsampled_registration_channel(reg)) as tif:
        downsampled_shape = tif.series[0].shape
    print(f"{len(cells)} detections; full-res shape {full_shape} (zarr), voxel sizes "
          f"{voxel_sizes} um, orientation {raw_orientation}; downsampled {downsampled_shape}",
          flush=True)

    source_space = bgs.AnatomicalSpace(raw_orientation, shape=full_shape, resolution=voxel_sizes)
    downsampled_space = bgs.AnatomicalSpace(DOWNSAMPLED_ORIENTATION, downsampled_shape,
                                            resolution=atlas.resolution)
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    downsampled = source_space.map_points_to(downsampled_space, cells)
    pd.DataFrame(downsampled).to_hdf(out / "downsampled.points", key="df", mode="w")
    transformed, n_out = downsampled_points_to_atlas_fast(
        downsampled, atlas, deformation_fields, out / "atlas.points")
    print(f"{n_out} detections fall outside the deformation field", flush=True)

    summarise_points_by_atlas_region(cells, transformed, atlas, reg / "volumes.csv",
                                     out / "all_points.csv", out / "summary.csv")

    choice = {
        "registration": args.registration_name or reg.name,
        "atlas": brainreg["atlas"],
        "voxel_sizes_zyx_um": voxel_sizes,
        "raw_orientation": raw_orientation,
        "full_res_shape_zyx": list(full_shape),
        "n_detections": int(len(cells)),
        "n_outside_deformation_field": n_out,
        "detections": str(args.detections),
        "transformed_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    if args.evaluation is not None and args.evaluation.exists():
        evaluation = json.loads(args.evaluation.read_text())
        choice["registration_quality"] = evaluation
        if evaluation.get("quality") != "GOOD":
            print(f"WARNING: registration quality is {evaluation.get('quality')} "
                  f"({evaluation.get('verdict')}); points transformed anyway - check the QC "
                  f"figures", flush=True)
    (out / "registration_choice.json").write_text(json.dumps(choice, indent=2))
    print(f"summary -> {out / 'summary.csv'}", flush=True)


if __name__ == "__main__":
    main()
