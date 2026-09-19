#!/usr/bin/env python3
"""Panoramic long-term SOT using ODTrack, person detection, and OSNet ReID."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import time

import cv2
import numpy as np
from ultralytics import YOLO

from panorama_reid import OSNetIdentityEncoder, crop_box
from panorama_sot_core import (
    AngularTargetState,
    centered_cylindrical_bbox,
    cylindrical_bbox_to_spherical,
    erp_bbox_to_spherical,
    extract_cylindrical_viewport,
)
from run_panorama_odtrack import draw_spherical_box, frame_paths, load_odtrack, parse_bbox


def box_iou(first, second) -> float:
    ax, ay, aw, ah = first
    bx, by, bw, bh = second
    x1, y1 = max(ax, bx), max(ay, by)
    x2, y2 = min(ax + aw, bx + bw), min(ay + ah, by + bh)
    intersection = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    union = aw * ah + bw * bh - intersection
    return intersection / union if union > 0.0 else 0.0


def center_distance(box, width: int, height: int) -> float:
    x, y, box_width, box_height = box
    return math.hypot(x + box_width * 0.5 - width * 0.5, y + box_height * 0.5 - height * 0.5) / width


def normalized_area_consistency(box, reference_area: float) -> float:
    area = max(float(box[2]) * float(box[3]), 1.0)
    return math.exp(-abs(math.log(area / max(reference_area, 1.0))))


class IdentityGallery:
    def __init__(self, anchor: np.ndarray, capacity: int = 8) -> None:
        self.anchor = anchor
        self.features = [anchor]
        self.capacity = capacity

    def similarity(self, candidates: np.ndarray) -> np.ndarray:
        gallery = np.stack(self.features)
        similarities = candidates @ gallery.T
        top_count = min(3, similarities.shape[1])
        return np.sort(similarities, axis=1)[:, -top_count:].mean(axis=1)

    def update(self, feature: np.ndarray) -> None:
        feature = feature / max(np.linalg.norm(feature), 1e-12)
        self.features.append(feature)
        if len(self.features) > self.capacity:
            self.features.pop(1)


def detector_boxes(model: YOLO, image: np.ndarray, confidence: float) -> list[list[float]]:
    result = model.predict(image, imgsz=640, classes=[0], conf=confidence, verbose=False)[0]
    if result.boxes is None:
        return []
    boxes = []
    for xyxy in result.boxes.xyxy.detach().cpu().numpy():
        x1, y1, x2, y2 = xyxy.tolist()
        if x2 - x1 >= 8 and y2 - y1 >= 16:
            boxes.append([x1, y1, x2 - x1, y2 - y1])
    return boxes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--odtrack-repo", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--torchreid-repo", type=Path, required=True)
    parser.add_argument("--reid-checkpoint", type=Path, required=True)
    parser.add_argument("--detector", type=Path, required=True)
    parser.add_argument("--frames", type=Path, required=True)
    parser.add_argument("--init-bbox", type=parse_bbox, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--config", default="baseline")
    parser.add_argument("--viewport-size", type=int, default=640)
    parser.add_argument("--viewport-height", type=int, default=480)
    parser.add_argument("--fov", type=float, default=110.0)
    parser.add_argument("--fps", type=float, default=10.0)
    parser.add_argument("--max-frames", type=int, default=0)
    parser.add_argument("--detector-confidence", type=float, default=0.12)
    parser.add_argument("--identity-threshold", type=float, default=0.48)
    parser.add_argument("--detector-interval", type=int, default=1)
    parser.add_argument("--save-frames", action="store_true")
    args = parser.parse_args()

    paths = frame_paths(args.frames)
    if args.max_frames > 0:
        paths = paths[: args.max_frames]
    if not paths:
        raise RuntimeError(f"No images found in {args.frames}")
    args.output.mkdir(parents=True, exist_ok=False)

    first_bgr = cv2.imread(str(paths[0]), cv2.IMREAD_COLOR)
    erp_height, erp_width = first_bgr.shape[:2]
    bearing, elevation, angular_width, angular_height = erp_bbox_to_spherical(
        args.init_bbox, erp_width, erp_height
    )
    state = AngularTargetState(bearing, elevation, timestamp_s=0.0)
    local_bbox = centered_cylindrical_bbox(
        angular_width, angular_height, args.viewport_size, args.viewport_height, args.fov
    )
    first_view = extract_cylindrical_viewport(
        first_bgr, bearing, args.fov, (args.viewport_size, args.viewport_height)
    )

    tracker = load_odtrack(args.odtrack_repo, args.checkpoint, args.config)
    tracker.initialize(cv2.cvtColor(first_view, cv2.COLOR_BGR2RGB), {"init_bbox": local_bbox})
    identity_encoder = OSNetIdentityEncoder(args.torchreid_repo, args.reid_checkpoint)
    anchor = identity_encoder.encode([crop_box(first_view, local_bbox, padding=0.0)])[0]
    gallery = IdentityGallery(anchor)
    detector = YOLO(str(args.detector))
    reference_area = local_bbox[2] * local_bbox[3]

    predictions = []
    tracker_latencies = []
    total_latencies = []
    corrections = 0
    rejected = 0
    for frame_index, path in enumerate(paths):
        frame_start = time.perf_counter()
        bgr = cv2.imread(str(path), cv2.IMREAD_COLOR)
        timestamp = frame_index / args.fps
        source = "initial"
        identity_similarity = 1.0
        response_confidence = 1.0
        candidate_count = 1

        if frame_index > 0:
            predicted = state.predict(timestamp)
            viewport = extract_cylindrical_viewport(
                bgr,
                predicted.bearing_deg,
                args.fov,
                (args.viewport_size, args.viewport_height),
            )
            tracker.state = centered_cylindrical_bbox(
                angular_width,
                angular_height,
                args.viewport_size,
                args.viewport_height,
                args.fov,
            )
            start = time.perf_counter()
            result = tracker.track(cv2.cvtColor(viewport, cv2.COLOR_BGR2RGB))
            tracker_latencies.append(time.perf_counter() - start)
            sot_box = [float(value) for value in result["target_bbox"]]
            response_confidence = float(tracker.last_response_confidence)
            chosen_box = sot_box
            source = "odtrack"
            chosen_feature = identity_encoder.encode([crop_box(viewport, sot_box)])[0]
            identity_similarity = float(gallery.similarity(chosen_feature[None, :])[0])

            if frame_index % args.detector_interval == 0:
                detections = detector_boxes(detector, viewport, args.detector_confidence)
                candidate_count = len(detections)
                if detections:
                    features = identity_encoder.encode([crop_box(viewport, box) for box in detections])
                    similarities = gallery.similarity(features)
                    scores = []
                    for box, similarity in zip(detections, similarities):
                        motion = math.exp(-0.5 * (center_distance(box, args.viewport_size, args.viewport_height) / 0.28) ** 2)
                        overlap = box_iou(box, sot_box)
                        size = normalized_area_consistency(box, reference_area)
                        scores.append(0.62 * similarity + 0.20 * motion + 0.12 * overlap + 0.06 * size)
                    best_index = int(np.argmax(scores))
                    best_box = detections[best_index]
                    best_similarity = float(similarities[best_index])
                    sot_score = (
                        0.62 * identity_similarity
                        + 0.20 * math.exp(-0.5 * (center_distance(sot_box, args.viewport_size, args.viewport_height) / 0.28) ** 2)
                        + 0.12
                        + 0.06 * normalized_area_consistency(sot_box, reference_area)
                    )
                    if best_similarity >= args.identity_threshold and scores[best_index] > sot_score + 0.015:
                        chosen_box = best_box
                        chosen_feature = features[best_index]
                        identity_similarity = best_similarity
                        source = "detector_reid"
                        if box_iou(chosen_box, sot_box) < 0.55:
                            tracker.initialize(
                                cv2.cvtColor(viewport, cv2.COLOR_BGR2RGB),
                                {"init_bbox": chosen_box},
                            )
                            corrections += 1

            if identity_similarity < args.identity_threshold:
                rejected += 1
                chosen_box = centered_cylindrical_bbox(
                    angular_width,
                    angular_height,
                    args.viewport_size,
                    args.viewport_height,
                    args.fov,
                )
                source = "motion_hold"
            else:
                if frame_index % 15 == 0 and identity_similarity >= 0.60:
                    gallery.update(chosen_feature)
                reference_area = 0.9 * reference_area + 0.1 * chosen_box[2] * chosen_box[3]

            spherical = cylindrical_bbox_to_spherical(
                tuple(chosen_box),
                args.viewport_size,
                args.viewport_height,
                predicted.bearing_deg,
                args.fov,
            )
            bearing, elevation, angular_width, angular_height = spherical
            state = state.update(bearing, elevation, timestamp, confidence=identity_similarity)
        else:
            spherical = (bearing, elevation, angular_width, angular_height)

        total_latencies.append(time.perf_counter() - frame_start)
        draw_spherical_box(bgr, *spherical)
        cv2.putText(
            bgr,
            f"{frame_index} {source} id={identity_similarity:.2f}",
            (20, 35),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.8,
            (0, 220, 255),
            2,
            cv2.LINE_AA,
        )
        if args.save_frames:
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
                "identity_similarity": identity_similarity,
                "selection_source": source,
                "candidate_count": candidate_count,
            }
        )

    summary = {
        "frames": len(predictions),
        "mean_tracker_fps": len(tracker_latencies) / sum(tracker_latencies),
        "mean_end_to_end_fps": len(total_latencies) / sum(total_latencies),
        "corrections": corrections,
        "identity_rejections": rejected,
        "predictions": predictions,
    }
    (args.output / "predictions.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps({key: value for key, value in summary.items() if key != "predictions"}))


if __name__ == "__main__":
    main()
