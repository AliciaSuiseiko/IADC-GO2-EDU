#!/usr/bin/env python3
"""Evaluate panoramic person reacquisition after annotated visibility gaps."""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path

import cv2
import numpy as np
from ultralytics import YOLO

from evaluate_panorama_sot import circular_iou
from panorama_reid import OSNetIdentityEncoder, crop_box
from panorama_sot_core import (
    SphericalKalmanState,
    centered_cylindrical_bbox,
    circular_delta_degrees,
    cylindrical_bbox_to_spherical,
    erp_bbox_to_spherical,
    extract_cylindrical_viewport,
)


def parse_ground_truth(path: Path) -> dict[int, dict[int, tuple[float, float, float, float]]]:
    tracks: dict[int, dict[int, tuple[float, float, float, float]]] = defaultdict(dict)
    for line in path.read_text().splitlines():
        fields = [float(value) for value in line.split(",")]
        tracks[int(fields[1])][int(fields[0])] = tuple(fields[2:6])
    return dict(tracks)


def visibility_gaps(track: dict[int, tuple], minimum_gap: int) -> list[tuple[int, int, int]]:
    frames = sorted(track)
    return [
        (first, second, second - first - 1)
        for first, second in zip(frames, frames[1:])
        if second - first - 1 >= minimum_gap
    ]


def normalized(feature: np.ndarray) -> np.ndarray:
    return feature / max(float(np.linalg.norm(feature)), 1e-12)


def global_box(
    spherical: tuple[float, float, float, float], width: int, height: int
) -> tuple[float, float, float, float]:
    bearing, elevation, horizontal_extent, vertical_extent = spherical
    center_x = (bearing + 180.0) / 360.0 * width
    center_y = (90.0 - elevation) / 180.0 * height
    box_width = horizontal_extent / 360.0 * width
    box_height = vertical_extent / 180.0 * height
    return center_x - box_width * 0.5, center_y - box_height * 0.5, box_width, box_height


def target_crop(
    frame: np.ndarray,
    box: tuple[float, float, float, float],
    viewport_width: int,
    viewport_height: int,
    fov: float,
) -> np.ndarray:
    bearing, _, angular_width, angular_height = erp_bbox_to_spherical(
        box, frame.shape[1], frame.shape[0]
    )
    view = extract_cylindrical_viewport(
        frame, bearing, fov, (viewport_width, viewport_height)
    )
    local = centered_cylindrical_bbox(
        angular_width, angular_height, viewport_width, viewport_height, fov
    )
    return crop_box(view, local, padding=0.0)


def detector_candidates(
    frame: np.ndarray,
    detector: YOLO,
    identity_encoder: OSNetIdentityEncoder,
    viewport_width: int,
    viewport_height: int,
    fov: float,
    confidence: float,
    centers: list[float],
    detector_imgsz: int,
) -> list[dict]:
    candidates = []
    for center in centers:
        view = extract_cylindrical_viewport(
            frame, center, fov, (viewport_width, viewport_height)
        )
        prediction = detector.predict(
            view,
            imgsz=detector_imgsz,
            classes=[0],
            conf=confidence,
            verbose=False,
        )[0]
        if prediction.boxes is None:
            continue
        local_boxes = []
        detector_scores = []
        for xyxy, score in zip(
            prediction.boxes.xyxy.detach().cpu().numpy(),
            prediction.boxes.conf.detach().cpu().numpy(),
        ):
            x1, y1, x2, y2 = xyxy.tolist()
            if x2 - x1 >= 8 and y2 - y1 >= 16:
                local_boxes.append([x1, y1, x2 - x1, y2 - y1])
                detector_scores.append(float(score))
        if not local_boxes:
            continue
        features = identity_encoder.encode([crop_box(view, box) for box in local_boxes])
        for box, score, feature in zip(local_boxes, detector_scores, features):
            spherical = cylindrical_bbox_to_spherical(
                tuple(box), viewport_width, viewport_height, center, fov
            )
            item = {
                "box": global_box(spherical, frame.shape[1], frame.shape[0]),
                "spherical": spherical,
                "detector_confidence": score,
                "feature": normalized(feature),
            }
            duplicate = next(
                (
                    old
                    for old in candidates
                    if circular_iou(item["box"], old["box"], frame.shape[1], frame.shape[0])
                    >= 0.55
                ),
                None,
            )
            if duplicate is None:
                candidates.append(item)
            elif score > duplicate["detector_confidence"]:
                duplicate.update(item)
    return candidates


def matched_identity(
    candidate_box: tuple,
    frame_index: int,
    tracks: dict[int, dict[int, tuple]],
    width: int,
    height: int,
) -> tuple[int | None, float]:
    overlaps = [
        (circular_iou(candidate_box, boxes[frame_index], width, height), identity)
        for identity, boxes in tracks.items()
        if frame_index in boxes
    ]
    if not overlaps:
        return None, 0.0
    overlap, identity = max(overlaps)
    return identity, overlap


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=Path, required=True)
    parser.add_argument("--ground-truth", type=Path, required=True)
    parser.add_argument("--target-id", type=int, required=True)
    parser.add_argument("--torchreid-repo", type=Path, required=True)
    parser.add_argument("--reid-checkpoint", type=Path, required=True)
    parser.add_argument("--detector", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fps", type=float, default=10.0)
    parser.add_argument("--minimum-gap", type=int, default=3)
    parser.add_argument("--recovery-window", type=int, default=10)
    parser.add_argument("--detector-confidence", type=float, default=0.08)
    parser.add_argument("--detector-imgsz", type=int, default=1280)
    parser.add_argument("--viewport-width", type=int, default=640)
    parser.add_argument("--viewport-height", type=int, default=480)
    parser.add_argument("--fov", type=float, default=110.0)
    args = parser.parse_args()

    paths = sorted(args.frames.glob("*.jpg"))
    if not paths:
        paths = sorted(args.frames.glob("*.png"))
    tracks = parse_ground_truth(args.ground_truth)
    target = tracks[args.target_id]
    events = visibility_gaps(target, args.minimum_gap)
    if not events:
        raise RuntimeError(f"target {args.target_id} has no gap >= {args.minimum_gap} frames")

    identity_encoder = OSNetIdentityEncoder(args.torchreid_repo, args.reid_checkpoint)
    detector = YOLO(str(args.detector))
    first_index = min(target)
    first_frame = cv2.imread(str(paths[first_index]), cv2.IMREAD_COLOR)
    anchor = normalized(
        identity_encoder.encode(
            [target_crop(first_frame, target[first_index], args.viewport_width, args.viewport_height, args.fov)]
        )[0]
    )
    gallery = [anchor]
    initial = erp_bbox_to_spherical(
        target[first_index], first_frame.shape[1], first_frame.shape[0]
    )
    state = SphericalKalmanState.initialize(initial[0], initial[1], first_index / args.fps)
    reference_area = target[first_index][2] * target[first_index][3]
    event_results = []
    event_by_last_visible = {event[0]: event for event in events}

    for frame_index in sorted(target):
        if frame_index > max(event[1] for event in events) + args.recovery_window:
            break
        frame = cv2.imread(str(paths[frame_index]), cv2.IMREAD_COLOR)
        measurement = erp_bbox_to_spherical(
            target[frame_index], frame.shape[1], frame.shape[0]
        )
        state = state.update(measurement[0], measurement[1], frame_index / args.fps, 0.95)
        reference_area = 0.95 * reference_area + 0.05 * target[frame_index][2] * target[frame_index][3]
        if frame_index % 30 == 0:
            feature = normalized(
                identity_encoder.encode(
                    [target_crop(frame, target[frame_index], args.viewport_width, args.viewport_height, args.fov)]
                )[0]
            )
            if float(feature @ anchor) >= 0.60:
                gallery.append(feature)
                gallery = [gallery[0], *gallery[-7:]]
        if frame_index not in event_by_last_visible:
            continue

        last_visible, first_visible, gap = event_by_last_visible[frame_index]
        predicted = state.predict(first_visible / args.fps)
        recovered = None
        attempts = []
        for recovery_frame in range(first_visible, min(first_visible + args.recovery_window, len(paths))):
            image = cv2.imread(str(paths[recovery_frame]), cv2.IMREAD_COLOR)
            predicted = state.predict(recovery_frame / args.fps)
            # Search likely motion first, then cover the remaining sphere. Duplicates are
            # removed below, so overlapping views improve small-person recall safely.
            centers = [
                predicted.bearing_deg,
                predicted.bearing_deg - 55.0,
                predicted.bearing_deg + 55.0,
                predicted.bearing_deg + 180.0,
                -135.0,
                -45.0,
                45.0,
                135.0,
            ]
            centers = list(dict.fromkeys(round((value + 180.0) % 360.0 - 180.0, 3) for value in centers))
            candidates = detector_candidates(
                image,
                detector,
                identity_encoder,
                args.viewport_width,
                args.viewport_height,
                args.fov,
                args.detector_confidence,
                centers,
                args.detector_imgsz,
            )
            if not candidates:
                attempts.append({"frame": recovery_frame, "candidate_count": 0})
                continue
            gallery_matrix = np.stack(gallery)
            for candidate in candidates:
                similarities = gallery_matrix @ candidate["feature"]
                candidate["identity_score"] = float(np.sort(similarities)[-min(3, len(similarities)):].mean())
                candidate["anchor_score"] = float(anchor @ candidate["feature"])
                bearing, elevation, _, _ = candidate["spherical"]
                bearing_sigma = max(predicted.bearing_sigma_deg, 8.0)
                elevation_sigma = max(predicted.elevation_sigma_deg, 6.0)
                candidate["motion_score"] = math.exp(
                    -0.5
                    * (
                        (circular_delta_degrees(bearing, predicted.bearing_deg) / bearing_sigma) ** 2
                        + ((elevation - predicted.elevation_deg) / elevation_sigma) ** 2
                    )
                )
                area = max(candidate["box"][2] * candidate["box"][3], 1.0)
                candidate["size_score"] = math.exp(-abs(math.log(area / max(reference_area, 1.0))))
                candidate["fused_score"] = (
                    0.45 * candidate["identity_score"]
                    + 0.20 * candidate["anchor_score"]
                    + 0.18 * candidate["motion_score"]
                    + 0.10 * candidate["size_score"]
                    + 0.07 * candidate["detector_confidence"]
                )
                candidate["matched_id"], candidate["matched_iou"] = matched_identity(
                    candidate["box"], recovery_frame, tracks, image.shape[1], image.shape[0]
                )
            identity_choice = max(candidates, key=lambda item: item["identity_score"])
            fused_choice = max(candidates, key=lambda item: item["fused_score"])
            attempt = {
                "frame": recovery_frame,
                "candidate_count": len(candidates),
                "identity_only_id": identity_choice["matched_id"],
                "identity_only_iou": identity_choice["matched_iou"],
                "fused_id": fused_choice["matched_id"],
                "fused_iou": fused_choice["matched_iou"],
                "fused_score": fused_choice["fused_score"],
                "identity_score": fused_choice["identity_score"],
                "anchor_score": fused_choice["anchor_score"],
                "motion_score": fused_choice["motion_score"],
                "detector_confidence": fused_choice["detector_confidence"],
            }
            attempts.append(attempt)
            if fused_choice["matched_id"] == args.target_id and fused_choice["matched_iou"] >= 0.3:
                recovered = recovery_frame
                break
        event_results.append(
            {
                "last_visible_frame": last_visible,
                "first_reappearing_frame": first_visible,
                "gap_frames": gap,
                "prediction_sigma_deg": [predicted.bearing_sigma_deg, predicted.elevation_sigma_deg],
                "recovered_frame": recovered,
                "recovery_delay_frames": None if recovered is None else recovered - first_visible,
                "attempts": attempts,
            }
        )

    successful = [item for item in event_results if item["recovered_frame"] is not None]
    summary = {
        "sequence": args.frames.parent.name,
        "target_id": args.target_id,
        "events": len(event_results),
        "successful_recoveries": len(successful),
        "recovery_rate": len(successful) / len(event_results),
        "mean_recovery_delay_frames": (
            sum(item["recovery_delay_frames"] for item in successful) / len(successful)
            if successful
            else None
        ),
        "details": event_results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({key: value for key, value in summary.items() if key != "details"}, indent=2))


if __name__ == "__main__":
    main()
