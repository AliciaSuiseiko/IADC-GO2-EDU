#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


def robust_limits(values, lower=0.5, upper=99.5):
    return np.percentile(values, [lower, upper])


def equalize(left, right, padding=0.04):
    center = (left + right) / 2.0
    half = max((right - left) / 2.0, 1.0) * (1.0 + padding)
    return center - half, center + half


def sample(points, count=180000):
    if len(points) <= count:
        return points
    indices = np.linspace(0, len(points) - 1, count, dtype=np.int64)
    return points[indices]


def load_map(path):
    points = np.load(path)["points"].astype(np.float32)
    points = points[np.all(np.isfinite(points), axis=1)]
    if len(points) < 100:
        raise RuntimeError(f"insufficient map points in {path}: {len(points)}")
    return points


def draw_map(axes, points, title):
    shown = sample(points)
    x_limits = robust_limits(points[:, 0])
    y_limits = robust_limits(points[:, 1])
    z_limits = robust_limits(points[:, 2], 1.0, 99.0)
    z_span = max(z_limits[1] - z_limits[0], 0.5)

    top, side = axes
    top.scatter(
        shown[:, 0], shown[:, 1], c=shown[:, 2], s=0.22, cmap="turbo", rasterized=True
    )
    top.set_title(f"{title} - top view")
    top.set_xlabel("X forward (m)")
    top.set_ylabel("Y left (m)")
    top.set_xlim(*equalize(*x_limits))
    top.set_ylim(*equalize(*y_limits))
    top.set_aspect("equal", adjustable="box")

    side.scatter(
        shown[:, 0], shown[:, 2], c=shown[:, 2], s=0.22, cmap="turbo", rasterized=True
    )
    side.set_title(f"{title} - side view (level check)")
    side.set_xlabel("X forward (m)")
    side.set_ylabel("Z up (m)")
    side.set_xlim(*equalize(*x_limits))
    side.set_ylim(z_limits[0] - z_span * 0.08, z_limits[1] + z_span * 0.08)

    for axis in axes:
        axis.grid(True, alpha=0.18, linewidth=0.5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fast", type=Path, required=True)
    parser.add_argument("--elevator", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()

    fast = load_map(args.fast)
    elevator = load_map(args.elevator)
    plt.style.use("dark_background")
    figure, axes = plt.subplots(2, 2, figsize=(16, 11), dpi=170, constrained_layout=True)
    draw_map(axes[0], fast, "FAST-LIO2")
    draw_map(axes[1], elevator, "Elevator-LIO")
    figure.suptitle("Mid-360 bag 20260810-205807 | full replay | 0.10 m voxel map", fontsize=16)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(args.output, facecolor="#111318")
    plt.close(figure)

    if args.manifest:
        args.manifest.write_text(
            json.dumps(
                {
                    "bag_id": "mid360-motion-20260810-205807",
                    "fast_map": str(args.fast),
                    "elevator_map": str(args.elevator),
                    "screenshot": str(args.output),
                },
                indent=2,
            )
            + "\n",
            encoding="ascii",
        )


if __name__ == "__main__":
    main()
