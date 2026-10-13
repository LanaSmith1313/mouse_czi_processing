"""QC figures for the registration sweep of one brain.

render_all_variants  one cell per variant, every cell at the same coronal,
                     horizontal and sagittal planes; grid variants laid out as
                     bending energy (rows) x grid spacing (columns). The selected
                     variant is framed in green. Ported from
                     ~/scripts/automatic_registration/report.py.
render_best          the selected variant only: coronal slices spread along the
                     anteroposterior axis, plus one horizontal (transversal) and
                     one sagittal plane.

Both draw the warped structure boundaries (`boundaries.tiff`) over the unwarped
downsampled image, which is the same in every variant, and carry the verdict in
the header. The downsampled image is in atlas orientation (asr): axis 0 runs
anterior->posterior, axis 1 superior->inferior, axis 2 right->left.
"""

from __future__ import annotations

import json
import textwrap
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import tifffile  # noqa: E402
from matplotlib.patches import Rectangle  # noqa: E402

import registration_scoring  # noqa: E402

BOUNDARY_RGBA = (1.0, 0.25, 0.55, 0.85)   # magenta, visible on a grey image
SELECTED_EDGE = "#1a9e3f"
SELECTED_FACE = "#e6f4e9"
REJECTED_TEXT = "#9a9a9a"
QUALITY_COLOURS = {"GOOD": "#1a9e3f", "CHECK": "#d08a00", "BAD": "#b0001e"}
N_CORONAL = 8


# --- shared helpers -----------------------------------------------------------------


def _consensus_extent(cache_dir: Path) -> tuple[np.ndarray, int]:
    consensus = np.load(cache_dir / "consensus.npy")
    step = json.loads((cache_dir / "roi.json").read_text())["geometry_step"]
    return consensus, step


def _at(consensus: np.ndarray, step: int, axis: int, fraction: float) -> int:
    """Full-resolution index `fraction` of the way across the consensus along `axis`."""
    other = tuple(a for a in range(3) if a != axis)
    present = np.flatnonzero(consensus.any(axis=other))
    return int((present[0] + fraction * (present[-1] - present[0])) * step)


def overview_positions(cache_dir: Path) -> dict[str, int]:
    """Coronal, horizontal and sagittal indices, fixed per brain.

    The sagittal plane is taken a third of the way across rather than at the
    midline, where there are few structure boundaries to judge by.
    """
    consensus, step = _consensus_extent(cache_dir)
    return {"coronal": _at(consensus, step, 0, 0.5),
            "horizontal": _at(consensus, step, 1, 0.45),
            "sagittal": _at(consensus, step, 2, 0.3)}


def coronal(volume, z):
    return volume[z]                    # rows superior->inferior, cols right->left


def horizontal(volume, y):
    return volume[:, y, :].T            # rows right->left, cols anterior->posterior


def sagittal(volume, x):
    return volume[:, :, x].T            # rows superior->inferior, cols anterior->posterior


def three_planes(volume: np.ndarray, pos: dict[str, int]) -> list[np.ndarray]:
    return [coronal(volume, pos["coronal"]), horizontal(volume, pos["horizontal"]),
            sagittal(volume, pos["sagittal"])]


def contrast(images: list[np.ndarray]) -> tuple[float, float]:
    values = np.concatenate([p[p > 0].ravel() for p in images])
    return tuple(np.percentile(values, [0.5, 99.8])) if values.size else (0.0, 1.0)


def draw(ax, image, shell, vmin, vmax):
    ax.imshow(image, cmap="gray", vmin=vmin, vmax=vmax, interpolation="nearest")
    overlay = np.zeros(shell.shape + (4,), dtype=float)
    overlay[shell] = BOUNDARY_RGBA
    ax.imshow(overlay, interpolation="nearest")
    ax.set_axis_off()


def read_boundaries(variant: Path) -> np.ndarray:
    return tifffile.imread(variant / "boundaries.tiff") != 0


def header_text(evaluation: dict) -> tuple[str, str]:
    title = (f"{evaluation['brain']} — registration {evaluation['quality']} "
             f"({evaluation['verdict']})")
    if evaluation["suggested_next_step"] != "none":
        title += f" — next step: {evaluation['suggested_next_step']}"
    return title, evaluation["evaluation"]


def caption(row: pd.Series) -> str:
    lines = [
        row["label"].replace("/", "  "),
        f"Dice {row['dice']:.4f}   ASSD {row['assd_um']:.0f} µm",
        f"HD95 {row['hd95_um']:.0f} µm   edge {row['edge_ratio']:.3f}   "
        f"distortion {row['distortion_sd']:.3f}",
    ]
    if row.get("selected"):
        lines[0] = "★ SELECTED   " + lines[0]
    elif row.get("rejected_distortion"):
        lines.append("rejected: distortion above guard")
    return "\n".join(lines)


# --- all variants, same planes ------------------------------------------------------


def layout(table: pd.DataFrame) -> list[list[pd.Series | None]]:
    """Grid variants as be x gs, then the remaining variants three to a row."""
    grid = table[table["in_grid"]]
    bes = sorted(grid["bending_energy"].unique())
    gss = sorted(grid["grid_spacing"].unique(), reverse=True)
    n_cols = max(len(gss), 3)
    cells = []
    for be in bes:
        row = []
        for gs in gss:
            match = grid[(grid["bending_energy"] == be) & (grid["grid_spacing"] == gs)]
            row.append(match.iloc[0] if len(match) else None)
        cells.append(row + [None] * (n_cols - len(row)))
    others = [r for _, r in table[~table["in_grid"]].iterrows()]
    for i in range(0, len(others), n_cols):
        chunk = others[i:i + n_cols]
        cells.append(chunk + [None] * (n_cols - len(chunk)))
    return cells


def render_all_variants(brain: str, table: pd.DataFrame, evaluation: dict,
                        variants: dict[str, Path], cache_dir: Path, channel: int,
                        out_path: Path) -> Path:
    pos = overview_positions(cache_dir)
    first = variants[table["variant"].iloc[0]]
    image = tifffile.imread(registration_scoring.downsampled_path(first, channel))
    image_planes = three_planes(image, pos)
    del image
    vmin, vmax = contrast(image_planes)
    widths = [p.shape[1] for p in image_planes]
    height = max(p.shape[0] for p in image_planes)

    grid = layout(table)
    n_rows, n_cols = len(grid), len(grid[0])
    cell_w = 7.5
    cell_h = cell_w * height / sum(widths) + 1.3
    fig = plt.figure(figsize=(n_cols * cell_w, n_rows * cell_h + 1.6), dpi=110)
    header, body = fig.subfigures(2, 1, height_ratios=[1.6, n_rows * cell_h])
    title, text = header_text(evaluation)
    colour = QUALITY_COLOURS[evaluation["quality"]]
    header.text(0.01, 0.72, title, fontsize=20, weight="bold", color=colour)
    header.text(0.01, 0.12, "\n".join(textwrap.wrap(text, 60 * n_cols)), fontsize=11, va="bottom")
    header.text(0.99, 0.72, f"planes: coronal z={pos['coronal']}, horizontal y={pos['horizontal']}, "
                f"sagittal x={pos['sagittal']}  (brain space, 20 µm, channel {channel})",
                fontsize=9, ha="right", color="#555555")

    cells = np.atleast_2d(body.subfigures(n_rows, n_cols, wspace=0.02, hspace=0.04))
    for r, grid_row in enumerate(grid):
        for c, row in enumerate(grid_row):
            cell = cells[r, c]
            if row is None:
                continue
            axes = cell.subplots(1, 3, gridspec_kw={"width_ratios": widths, "wspace": 0.02,
                                                    "bottom": 0.27, "top": 0.98,
                                                    "left": 0.02, "right": 0.98})
            boundaries = read_boundaries(variants[row["variant"]])
            for ax, img, shell in zip(axes, image_planes, three_planes(boundaries, pos)):
                draw(ax, img, shell, vmin, vmax)
            del boundaries
            selected = bool(row.get("selected"))
            rejected = bool(row.get("rejected_distortion"))
            cell.text(0.5, 0.235, caption(row), ha="center", va="top", fontsize=10.5,
                      family="monospace", weight="bold" if selected else "normal",
                      color=REJECTED_TEXT if rejected and not selected else "black")
            if selected:
                cell.set_facecolor(SELECTED_FACE)
                cell.add_artist(Rectangle((0.004, 0.004), 0.992, 0.992, fill=False,
                                          transform=cell.transSubfigure,
                                          edgecolor=SELECTED_EDGE, linewidth=5))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path)
    plt.close(fig)
    print(f"figure -> {out_path}", flush=True)
    return out_path


# --- selected variant, many planes -------------------------------------------------------


def render_best(brain: str, table: pd.DataFrame, evaluation: dict,
                variants: dict[str, Path], cache_dir: Path, channel: int,
                out_path: Path) -> Path:
    consensus, step = _consensus_extent(cache_dir)
    zs = [_at(consensus, step, 0, f) for f in np.linspace(0.08, 0.92, N_CORONAL)]
    y = _at(consensus, step, 1, 0.45)
    x = _at(consensus, step, 2, 0.3)
    del consensus

    chosen = table[table["selected"]].iloc[0]
    variant = variants[chosen["variant"]]
    image = tifffile.imread(registration_scoring.downsampled_path(variant, channel))
    boundaries = read_boundaries(variant)
    cor = [(coronal(image, z), coronal(boundaries, z)) for z in zs]
    hor = (horizontal(image, y), horizontal(boundaries, y))
    sag = (sagittal(image, x), sagittal(boundaries, x))
    del image, boundaries
    vmin, vmax = contrast([c[0] for c in cor] + [hor[0], sag[0]])

    n_cor_cols = N_CORONAL // 2
    cor_h, cor_w = cor[0][0].shape
    hor_h, hor_w = hor[0].shape
    sag_h, sag_w = sag[0].shape
    fig_w = 22.0
    cor_row_h = fig_w / n_cor_cols * cor_h / cor_w
    # horizontal and sagittal side by side, scaled to share one height
    bottom_h = fig_w / (hor_w / hor_h + sag_w / sag_h)
    fig = plt.figure(figsize=(fig_w, 2.2 + 2 * (cor_row_h + 0.35) + bottom_h + 0.35), dpi=110)
    header, top, bottom = fig.subfigures(
        3, 1, height_ratios=[2.2, 2 * (cor_row_h + 0.35), bottom_h + 0.35])

    title, text = header_text(evaluation)
    colour = QUALITY_COLOURS[evaluation["quality"]]
    header.text(0.01, 0.78, title, fontsize=20, weight="bold", color=colour)
    header.text(0.01, 0.52,
                f"selected {chosen['label']}   Dice {chosen['dice']:.4f} (acceptable ≥ "
                f"{evaluation['acceptable_level']:.3f}, failed < {evaluation['failed_level']:.3f})   "
                f"ASSD {chosen['assd_um']:.0f} µm   HD95 {chosen['hd95_um']:.0f} µm   "
                f"distortion {chosen['distortion_sd']:.3f} (limit {evaluation['distortion_limit']:.3f})",
                fontsize=12, family="monospace")
    header.text(0.01, 0.05, "\n".join(textwrap.wrap(text, 200)), fontsize=11, va="bottom")
    badge = header.text(0.99, 0.78, evaluation["quality"], fontsize=26, weight="bold",
                        ha="right", color="white")
    badge.set_bbox({"facecolor": colour, "edgecolor": "none", "boxstyle": "round,pad=0.3"})

    axes = top.subplots(2, n_cor_cols, gridspec_kw={"wspace": 0.02, "hspace": 0.12,
                                                    "left": 0.01, "right": 0.99,
                                                    "top": 0.95, "bottom": 0.02})
    for ax, z, (img, shell) in zip(axes.ravel(), zs, cor):
        draw(ax, img, shell, vmin, vmax)
        ax.set_title(f"coronal z={z} ({z * registration_scoring.VOXEL_UM / 1000:.1f} mm)",
                     fontsize=10)

    axes = bottom.subplots(1, 2, gridspec_kw={"width_ratios": [hor_w / hor_h, sag_w / sag_h],
                                              "wspace": 0.02, "left": 0.01, "right": 0.99,
                                              "top": 0.93, "bottom": 0.01})
    draw(axes[0], *hor, vmin, vmax)
    axes[0].set_title(f"horizontal (transversal) y={y} — rows R→L, anterior on the left",
                      fontsize=10)
    draw(axes[1], *sag, vmin, vmax)
    axes[1].set_title(f"sagittal x={x} — anterior on the left", fontsize=10)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path)
    plt.close(fig)
    print(f"figure -> {out_path}", flush=True)
    return out_path
