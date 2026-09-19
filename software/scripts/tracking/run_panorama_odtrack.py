#!/usr/bin/env python3
"""Run unmodified ODTrack inside a target-centered panoramic viewport."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time
import types

import cv2
import numpy as np

from panorama_sot_core import (
    AngularTargetState,
    angles_to_erp_pixel,
    centered_viewport_bbox,
    erp_bbox_to_spherical,
    extract_perspective_viewport,
    viewport_bbox_to_spherical,
)


def parse_bbox(value: str) -> tuple[float, float, float, float]:
    values = tuple(float(item) for item in value.split(","))
    if len(values) != 4 or values[2] <= 0 or values[3] <= 0:
        raise argparse.ArgumentTypeError("bbox must be x,y,width,height with positive size")
    return values


def load_odtrack(repo: Path, checkpoint: Path, config_name: str):
    # ODTrack still imports torch._six, which was removed after PyTorch 1.x.
    # Keep the compatibility surface local to this adapter instead of editing
    # the pinned upstream repository.
    if "torch._six" not in sys.modules:
        torch_six = types.ModuleType("torch._six")
        torch_six.string_classes = (str, bytes)
        torch_six.int_classes = int
        sys.modules["torch._six"] = torch_six

    # The upstream training package imports jpeg4py unconditionally even though
    # live inference passes numpy frames and never uses its dataset loader.
    if "jpeg4py" not in sys.modules:
        jpeg4py = types.ModuleType("jpeg4py")

        class UnsupportedJpegReader:
            def __init__(self, *_args, **_kwargs):
                raise RuntimeError("jpeg4py dataset loading is unavailable in live inference")

        jpeg4py.JPEG = UnsupportedJpegReader
        sys.modules["jpeg4py"] = jpeg4py
    if "visdom" not in sys.modules:
        visdom = types.ModuleType("visdom")

        class DisabledVisdom:
            def __init__(self, *_args, **_kwargs):
                pass

        visdom.Visdom = DisabledVisdom
        visdom.__path__ = []
        sys.modules["visdom"] = visdom
        visdom_server = types.ModuleType("visdom.server")
        visdom_server.download_scripts = lambda *_args, **_kwargs: None
        sys.modules["visdom.server"] = visdom_server

    sys.path.insert(0, str(repo))
    from lib.config.odtrack.config import cfg, update_config_from_file
    from lib.test.tracker.odtrack import ODTrack
    from lib.test.utils import TrackerParams

    update_config_from_file(str(repo / "experiments" / "odtrack" / f"{config_name}.yaml"))
    params = TrackerParams()
    params.cfg = cfg
    params.template_factor = cfg.TEST.TEMPLATE_FACTOR
    params.template_size = cfg.TEST.TEMPLATE_SIZE
    params.search_factor = cfg.TEST.SEARCH_FACTOR
    params.search_size = cfg.TEST.SEARCH_SIZE
    params.checkpoint = str(checkpoint)
    params.debug = 0
    params.save_all_boxes = False
    tracker = ODTrack(params)
    tracker.last_response_confidence = None
    original_forward = tracker.network.forward

    def capture_response_confidence(*args, **kwargs):
        output = original_forward(*args, **kwargs)
        final_output = output[-1] if isinstance(output, list) else output
        response = tracker.output_window * final_output["score_map"]
        tracker.last_response_confidence = float(response.max().detach().cpu())
        return output

    tracker.network.forward = capture_response_confidence
    return tracker


def frame_paths(path: Path) -> list[Path]:
    if path.is_file():
        raise ValueError("Use --video for video input; --frames expects an image directory")
    paths = []
    for pattern in ("*.jpg", "*.jpeg", "*.png"):
        paths.extend(path.glob(pattern))
    return sorted(paths)


def draw_spherical_box(
    image: np.ndarray,
    bearing_deg: float,
    elevation_deg: float,
    horizontal_extent_deg: float,
    vertical_extent_deg: float,
) -> None:
    height, width = image.shape[:2]
    center_x, center_y = angles_to_erp_pixel(bearing_deg, elevation_deg, width, height)
    box_width = horizontal_extent_deg / 360.0 * width
    box_height = vertical_extent_deg / 180.0 * height
    x1 = center_x - box_width * 0.5
    y1 = max(center_y - box_height * 0.5, 0.0)
    y2 = min(center_y + box_height * 0.5, height - 1.0)
    for shift in (-width, 0, width):
        left = int(round(x1 + shift))
        right = int(round(x1 + box_width + shift))
        if right < 0 or left >= width:
            continue
        cv2.rectangle(
            image,
            (max(left, 0), int(round(y1))),
            (min(right, width - 1), int(round(y2))),
            (0, 220, 255),
            3,
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--odtrack-repo", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--config", default="baseline")
    parser.add_argument("--frames", type=Path, required=True)
    parser.add_argument("--init-bbox", type=parse_bbox, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--viewport-size", type=int, default=640)
    parser.add_argument("--fov", type=float, default=100.0)
    parser.add_argument("--fps", type=float, default=10.0)
    parser.add_argument("--max-frames", type=int, default=0)
    args = parser.parse_args()

    paths = frame_paths(args.frames)
    if args.max_frames > 0:
        paths = paths[: args.max_frames]
    if not paths:
        raise RuntimeError(f"No images found in {args.frames}")

    first_bgr = cv2.imread(str(paths[0]), cv2.IMREAD_COLOR)
    if first_bgr is None:
        raise RuntimeError(f"Cannot read {paths[0]}")
    erp_height, erp_width = first_bgr.shape[:2]
    bearing, elevation, angular_width, angular_height = erp_bbox_to_spherical(
        args.init_bbox, erp_width, erp_height
    )
    state = AngularTargetState(bearing, elevation, timestamp_s=0.0)
    local_bbox = centered_viewport_bbox(
        angular_width,
        angular_height,
        args.viewport_size,
        args.viewport_size,
        args.fov,
    )
    first_view = extract_perspective_viewport(
        first_bgr,
        bearing,
        elevation,
        args.fov,
        (args.viewport_size, args.viewport_size),
    )
    tracker = load_odtrack(args.odtrack_repo, args.checkpoint, args.config)
    tracker.initialize(cv2.cvtColor(first_view, cv2.COLOR_BGR2RGB), {"init_bbox": local_bbox})

    args.output.mkdir(parents=True, exist_ok=False)
    predictions = []
    latencies = []
    for frame_index, path in enumerate(paths):
        bgr = cv2.imread(str(path), cv2.IMREAD_COLOR)
        timestamp = frame_index / args.fps
        if frame_index == 0:
            spherical = (bearing, elevation, angular_width, angular_height)
            response_confidence = 1.0
        else:
            predicted = state.predict(timestamp)
            viewport = extract_perspective_viewport(
                bgr,
                predicted.bearing_deg,
                predicted.elevation_deg,
                args.fov,
                (args.viewport_size, args.viewport_size),
            )
            tracker.state = centered_viewport_bbox(
                angular_width,
                angular_height,
                args.viewport_size,
                args.viewport_size,
                args.fov,
            )
            start = time.perf_counter()
            result = tracker.track(cv2.cvtColor(viewport, cv2.COLOR_BGR2RGB))
            response_confidence = tracker.last_response_confidence
            latencies.append(time.perf_counter() - start)
            spherical = viewport_bbox_to_spherical(
                tuple(result["target_bbox"]),
                args.viewport_size,
                args.viewport_size,
                predicted.bearing_deg,
                predicted.elevation_deg,
                args.fov,
            )
            bearing, elevation, angular_width, angular_height = spherical
            state = state.update(bearing, elevation, timestamp, confidence=1.0)

        draw_spherical_box(bgr, *spherical)
        cv2.putText(
            bgr,
            f"frame {frame_index} bearing {spherical[0]:.1f} deg",
            (20, 35),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.8,
            (0, 220, 255),
            2,
            cv2.LINE_AA,
        )
        cv2.imwrite(str(args.output / f"{frame_index:06d}.jpg"), bgr)
        predictions.append(
            {
                "frame": frame_index,
                "source": path.name,
                "bearing_deg": spherical[0],
                "elevation_deg": spherical[1],
                "horizontal_extent_deg": spherical[2],
                "vertical_extent_deg": spherical[3],
                "response_confidence": response_confidence,
            }
        )

    summary = {
        "frames": len(predictions),
        "mean_tracker_fps": len(latencies) / sum(latencies) if latencies else None,
        "config": args.config,
        "checkpoint": str(args.checkpoint),
        "fov_deg": args.fov,
        "predictions": predictions,
    }
    (args.output / "predictions.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps({key: value for key, value in summary.items() if key != "predictions"}))


if __name__ == "__main__":
    main()
