#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def distribution(values: np.ndarray) -> dict[str, float]:
    return {
        "median": float(np.median(values)),
        "p90": float(np.percentile(values, 90)),
        "p95": float(np.percentile(values, 95)),
        "p99": float(np.percentile(values, 99)),
        "max": float(np.max(values)),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--images", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--depth-scale", type=float, default=100.0)
    args = parser.parse_args()

    depth_paths = sorted(args.run.glob("frame-*/depth.npy"))
    image_paths = sorted(args.images.glob("frame-*.jpg"))
    if len(depth_paths) < 2 or len(depth_paths) != len(image_paths):
        raise SystemExit("depth/image sequence is incomplete")

    depths = np.stack([np.load(path) for path in depth_paths]).astype(np.float32) * args.depth_scale
    images = np.stack(
        [cv2.resize(cv2.imread(str(path)), (depths.shape[2], depths.shape[1])) for path in image_paths]
    ).astype(np.float32)
    valid = np.isfinite(depths).all(axis=0) & (depths.mean(axis=0) > 0.3)
    depth_mean = depths.mean(axis=0)
    depth_std = depths.std(axis=0)
    temporal_range = depths.max(axis=0) - depths.min(axis=0)
    relative_std = depth_std / np.maximum(depth_mean, 0.3)
    adjacent_depth_delta = np.abs(np.diff(depths, axis=0))[:, valid]
    adjacent_image_delta = np.mean(np.abs(np.diff(images, axis=0)), axis=3)

    bins = {}
    for lower, upper in ((0.3, 3.0), (3.0, 10.0), (10.0, 25.0)):
        mask = valid & (depth_mean >= lower) & (depth_mean < upper)
        if np.any(mask):
            bins[f"{lower:g}-{upper:g}m"] = {
                "pixels": int(mask.sum()),
                "std_m": distribution(depth_std[mask]),
                "relative_std": distribution(relative_std[mask]),
            }

    summary = {
        "frames": len(depth_paths),
        "depth_scale_to_meters": args.depth_scale,
        "valid_pixels": int(valid.sum()),
        "valid_fraction": float(valid.mean()),
        "mean_depth_m": distribution(depth_mean[valid]),
        "per_pixel_std_m": distribution(depth_std[valid]),
        "per_pixel_temporal_range_m": distribution(temporal_range[valid]),
        "per_pixel_relative_std": distribution(relative_std[valid]),
        "adjacent_absolute_delta_m": distribution(adjacent_depth_delta),
        "adjacent_image_delta_8bit": distribution(adjacent_image_delta.reshape(-1)),
        "depth_bins": bins,
    }

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "temporal_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    heat = np.clip(depth_std / 0.25, 0.0, 1.0)
    cv2.imwrite(str(args.output / "temporal-std-0-to-0.25m.png"), cv2.applyColorMap((heat * 255).astype(np.uint8), cv2.COLORMAP_TURBO))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
