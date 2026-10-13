"""Brain-space scoring of every registration variant of one brain.

Ported from ~/scripts/automatic_registration (scoring.py + brain_mask.py), where
the method was developed and validated against hand-picked registrations.

The unwarped downsampled registration channel is the same in every variant, so
the tissue mask and image gradient are computed once per brain and held fixed;
the only thing that changes between variants is the warped annotation, which is
recovered by flood-filling that variant's `boundaries.tiff`. Each variant gets:

  dice           volume-matched Dice between tissue mask and warped annotation
                 (the selection objective)
  assd_um, hd95_um, edge_ratio
                 reported for diagnosis only
  distortion_sd  spread of per-structure log volume ratios against the unwarped
                 atlas after removing global scale (regularity guard)

The consensus ROI used to clip artefacts far from the brain is built from every
variant that shares the most common affine setting (the sweep grid) and frozen,
so it does not depend on which variant is being scored.
"""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

import numpy as np
import pandas as pd
import tifffile
from scipy import ndimage as ndi

VOXEL_UM = 20.0

# Surface metrics run at 40 um (every 2nd voxel); validated in registration_qc.py.
GEOMETRY_STEP = 2

# Anteroposterior range scored, as fractions of the consensus annotation's
# extent: drops the olfactory bulb and the posterior cut face.
CORE_FRACTIONS = (0.222, 0.950)

# Tissue mask: 3 robust SDs above the background mode (4 leaks into ventricles).
BACKGROUND_SIGMA = 3.0

# Tissue further than this from the consensus annotation is treated as artefact.
ROI_MARGIN_UM = 1000.0
# A voxel is in the consensus if at least this fraction of the variants agree.
CONSENSUS_FRACTION = 5 / 9

AFFINE_KEYS = (
    "affine_n_steps",
    "affine_use_n_steps",
    "smoothing_sigma_reference",
    "smoothing_sigma_floating",
    "histogram_n_bins_floating",
    "histogram_n_bins_reference",
)

# Tissue segmentation (brain_mask.py): smoothing before segmenting and the
# closing that seals narrow gaps in the boundary, both in 20 um voxels.
SEGMENTATION_SIGMA_VOXELS = 3.0
CLOSING_VOXELS = 5


# --- variants ----------------------------------------------------------------


def variant_params(variant: Path) -> dict:
    return json.loads((variant / "brainreg.json").read_text())


def affine_key(params: dict) -> tuple:
    return tuple(float(params[k]) for k in AFFINE_KEYS)


def variant_label(params: dict, grid_affine: tuple) -> str:
    """Short label: be/gs, plus any affine setting that differs from the grid's."""
    label = f"be{float(params['bending_energy_weight']):g}/gs{int(params['grid_spacing'])}"
    short = {
        "affine_n_steps": "aff", "affine_use_n_steps": "affuse",
        "smoothing_sigma_reference": "sigR", "smoothing_sigma_floating": "sigF",
        "histogram_n_bins_floating": "binF", "histogram_n_bins_reference": "binR",
    }
    extras = [f"{short[k]}{float(params[k]):g}"
              for k, v in zip(AFFINE_KEYS, grid_affine) if float(params[k]) != v]
    return label + ("/" + ",".join(extras) if extras else "")


def downsampled_path(variant: Path, channel: int) -> Path:
    """The unwarped downsampled image of `channel` in `variant`.

    The pipeline names it `downsampled_<fused basename>_C<n>.tiff`; plain
    brainreg writes the primary channel as `downsampled.tiff`, and older brains
    registered from a folder named ch<n> give `downsampled_ch<n>.tiff`.
    """
    matches = [p for p in variant.glob(f"downsampled_*_C{channel}.tiff")
               if not p.name.startswith("downsampled_standard_")]
    if len(matches) == 1:
        return matches[0]
    if channel == 0 and (variant / "downsampled.tiff").exists():
        return variant / "downsampled.tiff"
    if (variant / f"downsampled_ch{channel}.tiff").exists():
        return variant / f"downsampled_ch{channel}.tiff"
    raise FileNotFoundError(f"No downsampled C{channel} in {variant}")


# --- tissue mask (brain_mask.py) ---------------------------------------------------


def robust_background_threshold(image: np.ndarray, n_sigma: float = 4.0) -> float:
    """Background level from the histogram's dominant mode.

    Background is by far the most common value in these frames, so the peak
    locates it directly; the spread is taken from the values below the peak
    only, which tissue cannot contaminate. (An Otsu-based estimate lands inside
    the tissue on raw downsampled stacks.)
    """
    nonzero = image[image > 0]
    counts, edges = np.histogram(nonzero, bins=512)
    mode = float((edges[:-1] + edges[1:])[counts.argmax()] / 2.0)
    below = nonzero[nonzero <= mode]
    spread = float(np.median(np.abs(below - mode))) * 1.4826
    return mode + n_sigma * spread


def build_brain_mask(image: np.ndarray, threshold: float) -> np.ndarray:
    """Segment the tissue by flood-filling the dim background in from the edges.

    Dim tissue in the interior is kept because it is enclosed, and interior
    spaces like the ventricles are filled for free.
    """
    smoothed = ndi.gaussian_filter(image.astype(np.float32), SEGMENTATION_SIGMA_VOXELS)
    dim = smoothed < threshold
    labels, _ = ndi.label(dim)
    background_labels = np.unique(labels[_edge(dim.shape) & dim])
    background = np.isin(labels, background_labels[background_labels > 0])
    mask = ndi.binary_closing(~background, np.ones((CLOSING_VOXELS,) * 3))
    labels, _ = ndi.label(mask)
    sizes = np.bincount(labels.ravel())
    sizes[0] = 0
    return labels == sizes.argmax()


# --- geometry helpers ----------------------------------------------------------


def _edge(shape) -> np.ndarray:
    edge = np.zeros(shape, dtype=bool)
    edge[0] = edge[-1] = True
    edge[:, 0] = edge[:, -1] = True
    edge[:, :, 0] = edge[:, :, -1] = True
    return edge


def subsample(volume: np.ndarray, step: int = GEOMETRY_STEP) -> np.ndarray:
    """Every `step`-th voxel, after trimming to a whole multiple of `step`."""
    trimmed = volume[tuple(slice(0, s // step * step) for s in volume.shape)]
    return np.ascontiguousarray(trimmed[::step, ::step, ::step])


def surface(mask: np.ndarray) -> np.ndarray:
    return mask & ~ndi.binary_erosion(mask)


def gradient_magnitude(volume: np.ndarray, sigma: float = 1.0) -> np.ndarray:
    smoothed = ndi.gaussian_filter(volume.astype(np.float32), sigma)
    return np.sqrt(sum(ndi.sobel(smoothed, axis) ** 2 for axis in range(3)))


def fill_from_edge(shell: np.ndarray) -> np.ndarray:
    """Everything `shell` encloses: the complement of what the edge can reach."""
    free = ~shell
    labels, _ = ndi.label(free)
    outside_labels = np.unique(labels[_edge(free.shape) & free])
    return ~np.isin(labels, outside_labels[outside_labels > 0])


def warped_annotation(variant: Path) -> tuple[np.ndarray, np.ndarray]:
    """(full-resolution brain mask, structure boundaries) of one variant.

    Filled at full resolution and only then subsampled by the caller -
    subsampling the one-voxel shell first punches holes the fill leaks through.
    """
    boundaries = tifffile.imread(variant / "boundaries.tiff") != 0
    return fill_from_edge(boundaries), boundaries


def core_slice(mask: np.ndarray) -> slice:
    present = np.flatnonzero(mask.any(axis=(1, 2)))
    if not present.size:
        return slice(None)
    first, last = int(present[0]), int(present[-1])
    span = last - first
    return slice(first + int(CORE_FRACTIONS[0] * span), first + int(CORE_FRACTIONS[1] * span))


def volume_matched(tissue_mask: np.ndarray, target_voxels: int, z_slice: slice):
    """Re-cut `tissue_mask` at the signed-distance level that matches the annotation volume.

    The intensity mask sits systematically inside the annotation; that offset
    belongs to the segmentation, not to any variant, so it is removed and only
    the shape is scored.
    """
    signed = (ndi.distance_transform_edt(~tissue_mask)
              - ndi.distance_transform_edt(tissue_mask)).astype(np.float32)
    core = signed[z_slice].ravel()
    target_voxels = int(min(max(target_voxels, 1), core.size))
    offset = float(np.partition(core, target_voxels - 1)[target_voxels - 1])
    return signed <= offset, offset * VOXEL_UM * GEOMETRY_STEP


def surface_metrics(tissue_mask, atlas_mask, z_slice) -> dict:
    """Dice and symmetric surface distances between tissue and warped annotation."""
    voxel_um = VOXEL_UM * GEOMETRY_STEP
    atlas_core = atlas_mask[z_slice]
    atlas_size = float(np.count_nonzero(atlas_core))
    tissue_size = float(np.count_nonzero(tissue_mask[z_slice]))
    raw_intersection = float(np.count_nonzero(tissue_mask[z_slice] & atlas_core))

    def core_only(mask):
        out = np.zeros_like(mask)
        out[z_slice] = mask[z_slice]
        return out

    atlas_surface = core_only(surface(atlas_mask))
    dist_to_atlas = ndi.distance_transform_edt(~atlas_surface) * voxel_um

    matched, inflation_um = volume_matched(tissue_mask, int(atlas_size), z_slice)
    matched_surface = core_only(surface(matched))
    dist_to_matched = ndi.distance_transform_edt(~matched_surface) * voxel_um

    both = np.concatenate([dist_to_atlas[matched_surface], dist_to_matched[atlas_surface]])
    matched_core = matched[z_slice]
    matched_size = float(np.count_nonzero(matched_core))
    matched_intersection = float(np.count_nonzero(matched_core & atlas_core))

    raw_surface = core_only(surface(tissue_mask))
    raw_to_atlas = dist_to_atlas[raw_surface]
    signed = np.where(~atlas_mask[raw_surface], raw_to_atlas, -raw_to_atlas)

    return {
        "dice": 2 * matched_intersection / (matched_size + atlas_size),
        "dice_raw": 2 * raw_intersection / (tissue_size + atlas_size),
        "assd_um": float(both.mean()),
        "hd95_um": float(np.percentile(both, 95)),
        "surface_median_um": float(np.median(both)),
        "assd_raw_um": float(raw_to_atlas.mean()),
        "signed_mean_um": float(signed.mean()),
        "inflation_um": inflation_um,
        "mask_ratio": tissue_size / max(atlas_size, 1.0),
        "annotation_volume_mm3": float(atlas_size * (voxel_um / 1000) ** 3),
    }


def edge_ratio(gradient, boundaries, brain_mask) -> float:
    """Image gradient on the warped structure boundaries over the rest of the brain."""
    on_boundary = boundaries & brain_mask
    elsewhere = brain_mask & ~boundaries
    if not on_boundary.any() or not elsewhere.any():
        return float("nan")
    return float(gradient[on_boundary].mean() / gradient[elsewhere].mean())


# --- deformation plausibility --------------------------------------------------


def reference_structure_volumes(atlas_dir: Path, cache_dir: Path) -> pd.Series:
    """Volume of every structure in the unwarped atlas, mm3 (cached)."""
    cache = cache_dir / f"reference_volumes_{atlas_dir.name}.csv"
    if cache.exists():
        return pd.read_csv(cache).set_index("structure_name")["total_volume_mm3"]
    annotation = tifffile.imread(atlas_dir / "annotation.tiff")
    ids, counts = np.unique(annotation, return_counts=True)
    name_by_id = pd.read_csv(atlas_dir / "structures.csv").set_index("id")["name"]
    volumes = pd.Series(counts * (VOXEL_UM / 1000) ** 3, index=ids)
    volumes = volumes[volumes.index.isin(name_by_id.index)]
    volumes.index = name_by_id.loc[volumes.index].values
    volumes.index.name = "structure_name"
    volumes.name = "total_volume_mm3"
    cache.parent.mkdir(parents=True, exist_ok=True)
    volumes.to_frame().to_csv(cache)
    return volumes


def distortion(variant: Path, reference: pd.Series, min_volume_mm3: float = 0.1) -> dict:
    """Spread of per-structure log volume ratios after removing global scale."""
    volumes = pd.read_csv(variant / "volumes.csv").set_index("structure_name")["total_volume_mm3"]
    shared = volumes.index.intersection(reference.index)
    shared = shared[(reference[shared] >= min_volume_mm3) & (volumes[shared] > 0)]
    log_ratio = np.log(volumes[shared] / reference[shared])
    scale = float(np.median(log_ratio))
    residual = log_ratio - scale
    return {
        "global_scale": float(np.exp(scale)),
        "distortion_sd": float(residual.std()),
        "brain_volume_mm3": float(volumes.sum()),
    }


# --- per-brain measurement ------------------------------------------------------


def measure_variants(variants: dict[str, Path], atlas_dir: Path, cache_dir: Path) -> pd.DataFrame:
    """Score every variant ({name: directory}) of one brain; one row per variant.

    Also writes `consensus.npy` and `roi.json` to `cache_dir`, which the figures
    use to place their slices.
    """
    cache_dir.mkdir(parents=True, exist_ok=True)
    params = {name: variant_params(d) for name, d in variants.items()}
    grid_affine = Counter(affine_key(p) for p in params.values()).most_common(1)[0][0]
    grid = [name for name, p in params.items() if affine_key(p) == grid_affine]

    first = variants[sorted(variants)[0]]
    image_path = downsampled_path(first, 0)
    image = tifffile.imread(image_path)
    threshold = robust_background_threshold(image, BACKGROUND_SIGMA)
    tissue = subsample(build_brain_mask(image, threshold))
    gradient = gradient_magnitude(image).astype(np.float32)
    del image
    print(f"tissue mask from {image_path.name} (threshold {threshold:.1f})", flush=True)

    annotations, ratios = {}, {}
    for name, d in variants.items():
        mask_full, boundaries = warped_annotation(d)
        ratios[name] = edge_ratio(gradient, boundaries, mask_full)
        annotations[name] = subsample(mask_full)
        del mask_full, boundaries
        print(f"  loaded {name}", flush=True)
    del gradient

    votes = np.sum([annotations[n] for n in grid], axis=0)
    consensus = votes >= np.ceil(CONSENSUS_FRACTION * len(grid))
    roi = ndi.distance_transform_edt(~consensus) <= ROI_MARGIN_UM / (VOXEL_UM * GEOMETRY_STEP)
    z_slice = core_slice(consensus)
    np.save(cache_dir / "consensus.npy", consensus)
    (cache_dir / "roi.json").write_text(json.dumps(
        {"grid_variants": sorted(grid), "core_z": [int(z_slice.start), int(z_slice.stop)],
         "geometry_step": GEOMETRY_STEP}, indent=2))

    tissue_roi = tissue & roi
    clipped = 1.0 - tissue_roi.sum() / max(tissue.sum(), 1)
    reference = reference_structure_volumes(atlas_dir, cache_dir)

    rows = []
    for name, d in variants.items():
        p = params[name]
        row = {
            "variant": name,
            "label": variant_label(p, grid_affine),
            "in_grid": name in grid,
            "bending_energy": float(p["bending_energy_weight"]),
            "grid_spacing": int(p["grid_spacing"]),
            **{k: float(p[k]) for k in AFFINE_KEYS},
            "mask_threshold": threshold,
            "core_z": [int(z_slice.start), int(z_slice.stop)],
            "tissue_clipped_fraction": float(clipped),
            "edge_ratio": ratios[name],
        }
        row.update(surface_metrics(tissue_roi, annotations[name], z_slice))
        row.update(distortion(d, reference))
        rows.append(row)
        print(f"  {row['label']}: Dice {row['dice']:.4f}, distortion {row['distortion_sd']:.3f}",
              flush=True)

    return (pd.DataFrame(rows)
            .sort_values(["in_grid", "bending_energy", "grid_spacing"], ascending=[False, True, True])
            .reset_index(drop=True))
