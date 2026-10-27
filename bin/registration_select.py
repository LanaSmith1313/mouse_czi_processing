#!/usr/bin/env python3
"""Score every registration variant of one brain, pick the best, draw the QC figures.

    registration_select.py --brain MS214 --atlas-dir <cache>/perens_lsfm_mouse_20um_v1.2 \
        --variant <name>=<dir> [--variant <name>=<dir> ...] [--out registration_qc]

Selection (from ~/scripts/automatic_registration/registration_search_design.md):
among variants that pass the regularity guard (distortion_sd at most
2x the prior median), the highest brain-space Dice wins - but every variant
within tau Dice of it is treated as tied, since the metric cannot order
differences that small, and the tie goes to the smoothest warp (lowest
distortion_sd).

The verdict compares the best Dice with quality levels from a prior cohort
(acceptable = median - 2 MAD, failed = median - 3 MAD; Dice < 0.90 is
catastrophic anywhere). The pipeline only runs the sweep grid, so the "next
step" is a suggestion; the adaptive search in automatic_registration/driver.py
can act on it.

Writes to --out:
  scores.csv                         one row per variant, `selected` marks the winner
  evaluation.json                    verdict, quality, suggested next step, chosen scores
  selected.txt                       name of the chosen variant
  <brain>_registration_variants.png  all variants on the same slices, winner framed
  <brain>_registration_best.png      chosen variant over coronal slices + two other planes
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import pandas as pd

import registration_figures
import registration_scoring

QUALITY = {  # verdict -> one-word answer to "is this registration usable?"
    "good": "GOOD", "good (borderline)": "CHECK", "mediocre": "CHECK",
    "check mask": "CHECK", "failed": "BAD", "catastrophic": "BAD",
}


def select(table: pd.DataFrame, limit: float, tau: float) -> pd.DataFrame:
    table = table.copy()
    table["rejected_distortion"] = table["distortion_sd"] > limit
    admissible = table[~table["rejected_distortion"]]
    if admissible.empty:
        admissible = table
    best = admissible["dice"].max()
    tied = admissible[admissible["dice"] >= best - tau]
    chosen = tied.sort_values(["distortion_sd", "dice"], ascending=[True, False]).index[0]
    table["selected"] = table.index == chosen
    return table


def evaluate(brain: str, table: pd.DataFrame, args) -> dict:
    chosen = table[table["selected"]].iloc[0]
    grid = table[table["in_grid"]]
    off_grid = table[~table["in_grid"]]
    acceptable = args.prior_median - 2 * args.prior_mad
    failed = args.prior_median - 3 * args.prior_mad
    admissible = table[~table["rejected_distortion"]]
    best = float((admissible if len(admissible) else table)["dice"].max())
    grid_max, grid_min = float(grid["dice"].max()), float(grid["dice"].min())
    spread = grid_max - grid_min
    clipped = float(chosen["tissue_clipped_fraction"])
    mask_ratio = float(chosen["mask_ratio"])
    lo, hi = args.mask_ratio_range

    notes = []
    # A tissue/annotation volume ratio far from 1 only implicates the mask when
    # the warp itself is plausible; when even the chosen variant fails the
    # distortion guard, the annotation is what has the wrong size.
    warp_plausible = not bool(chosen["rejected_distortion"])
    ratio_off = not lo < mask_ratio < hi
    if clipped > args.mask_clip_max or (ratio_off and warp_plausible):
        verdict, route = "check mask", "check by eye"
        notes.append(
            f"The tissue mask is suspect (clip removed {clipped:.1%}, limit "
            f"{args.mask_clip_max:.0%}; tissue/annotation volume {mask_ratio:.2f}, expected "
            f"{lo}-{hi}), so the scores may reflect the mask rather than the registration. "
            f"Inspect the figures before trusting the choice.")
    elif best < args.catastrophic_dice or (best < failed and spread < args.flat_spread):
        verdict = "catastrophic" if best < args.catastrophic_dice else "failed"
        why = (f"Best Dice {best:.3f} is below the catastrophic floor {args.catastrophic_dice}"
               if verdict == "catastrophic" else
               f"Best Dice {best:.3f} is below the failed level {failed:.3f} and the grid is "
               f"flat (spread {spread:.3f} < {args.flat_spread})")
        if off_grid.empty:
            route = "affine rescue suggested"
            notes.append(f"{why}. A uniformly low grid points at the affine stage or the input, "
                         f"not the freeform parameters: run the affine-rescue ladder "
                         f"(automatic_registration/driver.py) or check orientation, brain "
                         f"geometry, voxel sizes and the input stack.")
        else:
            route = "human check"
            notes.append(f"{why}. Check orientation, brain geometry, voxel sizes and the input "
                         f"stack, in that order.")
    elif best >= acceptable:
        borderline = best < acceptable + args.prior_mad
        verdict = "good (borderline)" if borderline else "good"
        route = "check by eye" if borderline else "none"
        notes.append(f"Best Dice {best:.3f} is at or above the acceptable level {acceptable:.3f}"
                     + (f", but within one MAD ({args.prior_mad:.4f}) of it, so look at the "
                        f"figures before using it." if borderline else "."))
    else:
        verdict = "mediocre" if best >= failed else "failed"
        route = "compass search suggested"
        notes.append(f"Best Dice {best:.3f} is below the acceptable level {acceptable:.3f}"
                     + (f" (and below the failed level {failed:.3f})" if verdict == "failed" else "")
                     + f", but the grid spread of {spread:.3f} says the freeform parameters "
                     f"matter, so a local search around the best variant "
                     f"(automatic_registration/driver.py) may improve it.")

    tied = admissible[admissible["dice"] >= best - args.tau]
    if len(tied) > 1:
        notes.append(f"{len(tied)} variants are within tau={args.tau} Dice of the best and cannot "
                     f"be ranked by the metric; the smoothest of them was chosen.")
    limit = args.distortion_guard_factor * args.distortion_prior_median
    n_rejected = int(table["rejected_distortion"].sum())
    if n_rejected == len(table):
        notes.append(f"Every variant fails the distortion guard (> {limit:.3f}; best "
                     f"{table['distortion_sd'].min():.3f}): the atlas has been scaled or "
                     f"distorted, not fitted. The chosen variant is the least bad, not a usable "
                     f"registration.")
    elif n_rejected:
        notes.append(f"{n_rejected} variant(s) rejected by the distortion guard (> {limit:.3f}).")

    return {
        "brain": brain,
        "quality": QUALITY[verdict],
        "verdict": verdict,
        "suggested_next_step": route,
        "evaluation": " ".join(notes),
        "selected_variant": chosen["variant"],
        "selected_label": chosen["label"],
        "bending_energy": float(chosen["bending_energy"]),
        "grid_spacing": int(chosen["grid_spacing"]),
        "dice": float(chosen["dice"]),
        "assd_um": float(chosen["assd_um"]),
        "hd95_um": float(chosen["hd95_um"]),
        "edge_ratio": float(chosen["edge_ratio"]),
        "distortion_sd": float(chosen["distortion_sd"]),
        "best_dice": best,
        "grid_dice_min": grid_min,
        "grid_dice_max": grid_max,
        "grid_spread": spread,
        "n_variants": len(table),
        "tissue_clipped_fraction": clipped,
        "mask_ratio": mask_ratio,
        "acceptable_level": acceptable,
        "failed_level": failed,
        "distortion_limit": limit,
        "scored_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }


def parse_variant(text: str) -> tuple[str, Path]:
    name, _, path = text.partition("=")
    if not name or not path:
        raise argparse.ArgumentTypeError(f"expected NAME=DIR, got {text!r}")
    return name, Path(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--brain", required=True)
    parser.add_argument("--atlas-dir", required=True, type=Path,
                        help="atlas folder holding annotation.tiff and structures.csv")
    parser.add_argument("--variant", required=True, action="append", type=parse_variant,
                        help="NAME=DIR, once per registration variant")
    parser.add_argument("--out", default="registration_qc", type=Path)
    parser.add_argument("--display-channel", type=int, default=1,
                        help="downsampled channel drawn under the boundaries")
    parser.add_argument("--tau", type=float, default=0.005)
    parser.add_argument("--prior-median", type=float, default=0.974)
    parser.add_argument("--prior-mad", type=float, default=0.0055)
    parser.add_argument("--catastrophic-dice", type=float, default=0.90)
    parser.add_argument("--flat-spread", type=float, default=0.06)
    parser.add_argument("--distortion-prior-median", type=float, default=0.033)
    parser.add_argument("--distortion-guard-factor", type=float, default=2.0)
    parser.add_argument("--mask-clip-max", type=float, default=0.02)
    parser.add_argument("--mask-ratio-range", type=float, nargs=2, default=(0.9, 1.1))
    args = parser.parse_args()

    variants = dict(args.variant)
    missing = [n for n, d in variants.items()
               if not ((d / "boundaries.tiff").exists() and (d / "volumes.csv").exists()
                       and (d / "brainreg.json").exists())]
    for name in missing:
        print(f"WARNING: {name} has no boundaries.tiff/volumes.csv/brainreg.json, skipped")
        del variants[name]
    if not variants:
        raise SystemExit("no complete registration variants to score")

    args.out.mkdir(parents=True, exist_ok=True)
    cache = args.out.parent / f"{args.out.name}_cache"   # not published
    table = registration_scoring.measure_variants(variants, args.atlas_dir, cache)
    limit = args.distortion_guard_factor * args.distortion_prior_median
    table = select(table, limit, args.tau)
    evaluation = evaluate(args.brain, table, args)

    table.to_csv(args.out / "scores.csv", index=False)
    (args.out / "evaluation.json").write_text(json.dumps(evaluation, indent=2))
    (args.out / "selected.txt").write_text(evaluation["selected_variant"] + "\n")
    print(f"{args.brain}: {evaluation['quality']} ({evaluation['verdict']}) - selected "
          f"{evaluation['selected_label']} (Dice {evaluation['dice']:.4f})", flush=True)
    print(evaluation["evaluation"], flush=True)

    # Single-channel brains have no C1: draw the registration channel (C0) instead
    display_channel = args.display_channel
    try:
        registration_scoring.downsampled_path(next(iter(variants.values())), display_channel)
    except FileNotFoundError:
        print(f"WARNING: no downsampled C{display_channel}, drawing figures on C0", flush=True)
        display_channel = 0

    registration_figures.render_all_variants(
        args.brain, table, evaluation, variants, cache, display_channel,
        args.out / f"{args.brain}_registration_variants.png")
    registration_figures.render_best(
        args.brain, table, evaluation, variants, cache, display_channel,
        args.out / f"{args.brain}_registration_best.png")


if __name__ == "__main__":
    main()
